# Audit 06 — CPU + GPU memory management and Vulkan allocation

Scope: VMA configuration, allocation sizing/fragmentation, buffer & image
allocation paths, staging/upload strategy, the CPU heap/newlib behaviour,
memory monitors, and asset caches. Read-only audit; this file is the only
artifact. Branch `perf/switch-audit`.

Device facts this is written against (docs/FINDINGS.md §1–4): one memory type
(`HOST_VISIBLE|HOST_COHERENT|HOST_CACHED`, no device-local), one ~2.4 GB heap
with a ~1843 MiB budget, `maxMemoryAllocationCount 4096`, VMA 3.4.0, driver
refuses single `vkAllocateMemory` above a *moving* cap (measured ~343 KB–1.1 MB
across runs), VMA blocks observed as a `32/16/8/4 MiB` ladder, newlib `malloc`
never returns pages to the OS (`sbrk` only grows).

Line numbers are from the checked-out tree. The central question — "why does a
16 KiB VMA buffer fail while the heap reports 1.8 GiB free?" — is answered in
§A below: this is a *block-growth* failure, not a size failure, and almost
every recommendation here is a way to grow fewer blocks and allocate fewer
things.

---

## 0. The failure shape, restated from the code

`vk_utils.cpp:142-159` logs, on a failed `vmaCreateBuffer`:

```
Failed to create VMA buffer (size=16384) result=-2 ...
liveBuffers=406 liveBufferBytes=8398672 liveImages=160 liveImageBytes=9891840
probe: allocation cap is between 225279 and 227497 bytes   (run 45)
blocks=26  blockBytes=121.5 MiB  allocs=231  unusedRanges=40
largest unused range = 13,632 bytes                        (run 23 failure)
```

Read together: VMA cannot fit the request in an existing block (largest hole
13 KiB) **and** cannot obtain a new block from the driver. The driver's
*new-allocation* cap (~343 KB at that moment, run 35) is what blocks growth —
while the reported budget is gigabytes. So:

- **The cap is not a VMA artifact.** It is the driver refusing a fresh
  `vkAllocateMemory` for a new VMA block. VMA suballocation inside an existing
  block is not subject to it — which is the whole lever.
- **Small `preferredLargeHeapBlockSize` makes the cap worse, not better.** Each
  new block is one `vkAllocateMemory` against the moving cap. Fewer, larger
  blocks = fewer capped calls. The current tree sets the *smallest* value
  (§M1).
- **The cheapest fix is to allocate fewer VMA objects**, so blocks fill more
  slowly and growth is rarer. Staging buffers are the dominant source of small
  transient VMA objects (§W1).

---

## A. Clear wins

### W1 — Pool and recycle staging buffers (largest churn source) — HIGH
**Evidence.** Every chunked upload allocates a fresh 256 KiB VMA staging buffer,
maps it, flushes it, and then destroys it (or defers destroy to batch retire):
`vk_utils.cpp:217,231,266`; `vk_texture.cpp:240,268,448,475`. The chunk size is
`256 * 1024` (`vk_utils.cpp:696`, `vk_texture.cpp:237,433`). A single 4 MiB
texture is 16 staging allocations; a mip chain is one per level (plus
row-slices for levels >256 KiB); every terrain chunk and every WMO/M2 mesh
goes through `uploadBuffer` → `uploadBytesChunked`. Each allocation is a
`vkCreateBuffer` + `vmaCreateBuffer` + `vmaMapMemory` + `vmaFlushAllocation` +
`vmaUnmapMemory` + (later) `vmaDestroyBuffer`, and a small object added to a
VMA block — exactly the objects that turned 26 blocks into a 13 KiB max hole.

**Recommendation.** A small size-classed pool of persistent host-visible staging
buffers (e.g. 256 KiB and 64 KiB buckets). `createBuffer`'s staging path borrows
from the pool instead of allocating; the existing retire points return buffers
to the pool instead of destroying them: `pollUploadBatches` (`vk_context.cpp:4304-4306`)
and `waitAllUploads` (`vk_context.cpp:4341-4343`), plus the
`deferStagingCleanup` ownership transfer (`vk_context.cpp:4357-4359`).

**Impact:** high — removes almost all staging allocation churn, reduces VMA
object count and block growth, and removes a large class of allocation failures
(256 KiB staging was refused in run 35). **Risk:** medium/low — a pooled buffer
must not be reused until its batch fence has signalled; the pool must be fed
only from the retire paths (never from `deferStagingCleanup`, where the buffer
is still owned by the in-flight batch). **Kind:** larger. **Switch-gate:** keep
the pool Switch-only, or enable everywhere (it is strictly better).

### W2 — Reuse one staging buffer for all slices when *not* batching — MED
**Evidence.** Outside an upload batch `immediateSubmit` submits and waits on
its own fence before returning (`vk_context.cpp:4095-4098`, `endSingleTimeCommands`).
Therefore a single staging buffer is safe across slices — the copy has
completed before the next `memcpy`. The sliced path in `uploadBytesChunked`
still allocates one staging buffer *per slice* regardless
(`vk_utils.cpp:261-286`), and `VkTexture` does the same (`vk_texture.cpp:262-291`,
`470-498`).

**Recommendation.** When `!ctx.isInUploadBatch()`, allocate one staging buffer
sized `min(chunkBytes, transferSize)` (bounded reuse) and reuse it across all
slices; only fall back to per-slice allocation inside a batch.

**Impact:** medium. **Risk:** low. **Kind:** quick win. **Switch-gate:** safe on
all platforms.

### W3 — Stop allocating images in the OOM probe — MED
**Evidence.** `createImage`'s failure path still *bisects the image ceiling by
allocating images* (`vk_utils.cpp:397-429`): it calls `vmaCreateImage` with
halving extents in a loop, then `vmaDestroyImage`. This runs precisely when the
heap is exhausted. The buffer probe was already disabled for this reason —
`reportAllocationProbe`'s comment: "Bisection probe disabled to avoid perturbing
heap during OOM" (`vk_utils.cpp:77`). The image path never got the same edit.

**Recommendation.** Remove the image bisection loop, or gate it behind an env
flag that is off by default. Keep the `reportVmaLayout`/stats line (allocation
free).

**Impact:** medium (stability under OOM; the probe can itself trigger the next
failure or a driver cleanup crash). **Risk:** low to remove. **Kind:** quick
win. **Switch-gate:** the loop is already `#ifdef WOWEE_SWITCH`; delete it.

### W4 — `SwitchAttachmentMemory` is dead code on this console — LOW
**Evidence.** `SwitchAttachmentMemoryTypeBits` (`switch_attachment_memory.hpp:7-18`)
builds a mask of types that are `DEVICE_LOCAL` and *not* `HOST_CACHED`. This
console's only type is `HOST_VISIBLE|HOST_COHERENT|HOST_CACHED`, so the mask is
always `0`; `allocateSwitchAttachment` then always takes the `preferred == 0`
fallback (`:30`) and `vk_utils.cpp:354-358` logs
`[SWITCH_ATTACHMENT_MEMORY] Garlic unavailable` for every attachment image.
"Garlic" is PS4 terminology — this is a PS4-era preference left in the Switch
path.

**Recommendation.** Short-circuit: when `preferred == 0` do not log the
fallback warning (it is the normal case here), and drop/rename the "Garlic"
message. Optionally fold the helper away on Switch.

**Impact:** low (log noise + one branch per attachment). **Risk:** none — the
allocation already falls back. **Kind:** quick win.

### W5 — Stale budget message in the monitor — LOW
**Evidence.** `memory_monitor.cpp:60-62` logs `"shared cache ceiling=32 MiB"`,
but `kCpuCacheBudgetLimit` was raised to 128 MiB (`cpu_budget.hpp:40`) and the
Switch cache budget now comes from `cpuFileCacheBudgetFor`
(`asset_manager.cpp:256`). The logged number is wrong.

**Recommendation.** Log `kCpuCacheBudgetLimit` (or drop the clause).

**Impact:** low (misleading telemetry). **Risk:** none. **Kind:** quick win.

### W6 — Stale comments that will mislead the next allocator change — LOW
**Evidence.**
- `vk_texture.cpp:422-427` says the mip "scratch is static and reused" — there
  is no static scratch; the function reads `mipData` directly and allocates
  fresh staging per level. The static-scratch fix described in FINDINGS §3 is
  not present as described.
- `cpu_budget.hpp` and `memory_monitor.cpp` still describe `musl`,
  `sceKernelAvailableFlexibleMemorySize`, and "flexible pages" (PS4), while the
  Switch path uses `svcGetInfo` (`cpu_memory.hpp:29`).
- `cpu_budget.hpp:8-29` narrates the PS4 `B39` session; the Switch caps are
  `448/3328 MiB` (`cpu_memory.hpp:38-40`), not `kCpuMemoryBudgetLimit` (2048).

**Recommendation.** Correct the comments; they are the map the next allocation
change will follow.

**Impact:** low (future-defect prevention). **Risk:** none. **Kind:** quick win.

### W7 — Cache hits copy the whole file — MED
**Evidence.** `readFileBounded` promotes the shared handle out of the lock but
then copies it: `auto data = *cached;` (`asset_manager.cpp:1012`). The entire
point of `ByteLruCache` is to avoid re-reading/decompressing, yet every hit
still copies the byte vector (hundreds of KiB to several MiB per read). Under
streaming this is real memcpy churn on top of an already-fragmented heap.

**Recommendation.** Return the `shared_ptr<const Bytes>` to callers, or provide
a `readFileShared` for the hot paths and migrate the biggest readers.

**Impact:** medium (CPU + transient allocation). **Risk:** medium — the API is
by-value `std::vector<uint8_t>` in many places; a mechanical migration is
larger. **Kind:** larger. **Switch-gate:** none.

### W8 — Missing VMA host-access / strategy hints — LOW/MED
**Evidence.** Buffers/images use the deprecated `VMA_MEMORY_USAGE_*` enums with
only `VMA_ALLOCATION_CREATE_MAPPED_BIT` (`vk_utils.cpp:119-123,335-336`), rather
than `VMA_MEMORY_USAGE_AUTO` + `VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT`.
`character_renderer.cpp:453` already demonstrates the newer flag pair, so the
codebase is inconsistent.

**Recommendation.** Do not churn everything, but for GPU resources consider
`VMA_ALLOCATION_CREATE_STRATEGY_MIN_MEMORY_BIT` to pack blocks tightly, and add
`VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT` to the allocator
(`vk_context.cpp:1101`) so a real budget is queryable.

**Impact:** low/medium (tighter packing = fewer holes). **Risk:** low. **Kind:**
quick win/measure. **Switch-gate:** none.

---

## B. Measure first

### M1 — `preferredLargeHeapBlockSize = 4 MiB` contradicts the project ledger — HIGH
**Evidence.** `vk_context.cpp:1134` sets `4u * 1024 * 1024` (commit `19dac7c`,
"vma: 4 MiB blocks"). But FINDINGS.md:65-66 says *"`preferredLargeHeapBlockSize`
is set to 32 MiB. **8 MiB broke the M2 transfers** — do not go lower."* and
FINDINGS.md:88 and AGENTS.md:286 repeat "stays 32 MiB". The tree is configured
with the value the ledger explicitly warns against.

**Why it matters.** See §0: every new block is one `vkAllocateMemory` against
the moving cap. A 4 MiB preferred size yields *more* blocks (and more capped
calls) than 32 MiB for the same live set — the opposite of what a fragmented
heap needs. It also risks re-breaking the M2 mega-buffer transfers the ledger
names. The current comment (`vk_context.cpp:1119-1133`) argues small blocks are
"still creatable," which is true but is exactly the property that *grows block
count* while the driver cap blocks growth.

**Recommendation.** Treat the code/doc divergence as a correctness risk. Either
restore 32 MiB (and re-verify M2 skeleton/animation transfers), or measure both
and record the block ladder + M2 transfer outcome in FINDINGS before keeping
4 MiB. Do not ship the value the ledger forbids without a new measurement.

**Impact:** high. **Risk:** high (a silent regression against a documented
constraint). **Kind:** measure-first. **Switch-gate:** the doc is Switch-specific.

### M2 — Pre-warm one or two large blocks at init, before fragmentation — HIGH
**Evidence.** The driver's new-allocation cap *moves* (343 KB–1.1 MB) as
fragmentation accrues (FINDINGS §2). At startup the address space is clean and
the cap is highest. VMA grows blocks lazily, so by the time the cap has fallen
the allocator is forced into the small-block ladder.

**Recommendation.** Create a VMA pool (`vmaCreatePool`) for the small,
long-lived, sub-1 MiB resources with `blockSize` large (e.g. 32 MiB) and
`minBlockCount = 1` so the block is reserved while memory is contiguous;
subsequent small allocations come from it and never call `vkAllocateMemory`
again. A second pool can serve staging. Measure block count via the existing
`reportVmaLayout` line.

**Impact:** high (directly targets the "cap while 1.8 GiB free" disease). **Risk:**
medium (pool sizing/`minBlockCount` misuse wastes memory; wrong pool routing
fragments instead). **Kind:** larger/measure-first. **Switch-gate:** Switch-only.

### M3 — Defragmentation at loading boundaries — MED
**Evidence.** VMA 3.4.0 provides `vmaBeginDefragmentation`. The 13 KiB max hole
is precisely what a defrag pass consolidates. The reclaim-and-retry
(`vk_utils.cpp:137,378`) is a poor man's version of this.

**Recommendation.** Consider a `vkDeviceWaitIdle` + defrag pass at loading-screen
boundaries when idle. Only allocations not mapped and not in flight may move.

**Impact:** medium. **Risk:** high (moving a mapped or in-flight allocation is a
use-after-free; many resources are `MAPPED_BIT` persistent). **Kind:**
measure-first; do not attempt without a fence-drained boundary. **Switch-gate:**
Switch-only.

### M4 — Give the DBC cache a byte budget — MED
**Evidence.** `dbcCache` (`asset_manager.cpp:714-940`) is an unbounded
`unordered_map` with no byte cap; Run 39 needed explicit eviction of ~20 DBCs to
stop heap bloat (FINDINGS Run 39). Correctness now depends on every caller
remembering to `evictDBC`. `previewModels_.clear()` is called on every evict,
which is churn.

**Recommendation.** Track bytes and trim LRU like `ByteLruCache`, or reuse
`ByteLruCache` semantics. Keep explicit eviction as belt-and-suspenders.

**Impact:** medium (retained MBs over a session). **Risk:** low. **Kind:**
larger/measure-first.

### M5 — Cache trim-to-zero oscillation under pressure — MED
**Evidence.** On `bad_alloc` the cache is emptied to zero
(`asset_manager.cpp:1020,1063,1112`), while `refreshSwitchCacheBudget` otherwise
trims to a 4 MiB floor (`cpu_budget.hpp:51`). Under sustained pressure the cache
can flip 0 → refill → 0, and each evicted byte is re-read and re-decompressed
(the very transient pressure the header warns about).

**Recommendation.** Trim to the floor (not 0) in the `bad_alloc` paths too, so
the hot set survives and repeat reads do not re-decompress.

**Impact:** medium. **Risk:** low. **Kind:** quick win/measure.

### M6 — Verify the halved Switch backpressure didn't just serialize loads — LOW
**Evidence.** Switch in-flight caps are 8 batches / 16 MiB
(`vk_context.cpp:4135-4141`) plus `serialUploads_` during entry
(`vk_context.cpp:4209-4217`). Run 53 showed serialization did not stop the entry
deaths; Run 56 survived once markers were deferred.

**Recommendation.** Once entry stability is settled, re-test whether the tighter
in-flight cap and serial mode can be relaxed for load throughput.

**Impact:** low (load time). **Risk:** low. **Kind:** measure-first.

---

## C. Memory-leak-class bugs (explicit)

### L1 — `createImage` returns a live image with a null view; unchecked callers leak
**Evidence.** When `vkCreateImageView` fails, `createImage` logs and returns
`result` with `image`/`allocation` valid and `imageView == VK_NULL_HANDLE`
(`vk_utils.cpp:469-473`). `VkTexture` checks for this and destroys
(`vk_texture.cpp:316,520,653`). But the render-target and post-process call
sites do not visibly guard the view before using/teardown:
`vk_render_target.cpp:21,32,43`; `post_process_pipeline.cpp:710-739,1000-1023,1756-1784`.
A view failure there leaves the image + allocation live past the renderer's own
teardown if it only checks `image`.

**Recommendation.** Have `createImage` destroy and return `{}` on view failure,
or audit every caller to check `imageView`. The former is safer.

**Impact:** medium (leak class, only on view-creation failure but exactly under
the conditions this console sees). **Risk:** low. **Kind:** quick win.

### L2 — Failed-fence batches are retained until device teardown (by design, but a leak)
**Evidence.** `pollUploadBatches` sets `deviceLost_` and returns without freeing
when a fence status is an error (`vk_context.cpp:4315-4319`); `waitAllUploads`
likewise returns leaving allocations owned (`:4328-4333`). This is deliberate
(never free memory a possibly-live GPU may read) but is unbounded retention.

**Recommendation.** Document as intended; on a clean teardown path ensure the
VMA allocator is destroyed after `vkDeviceWaitIdle`, which reclaims everything.
Not a fix, a boundary note.

**Impact:** low. **Risk:** n/a. **Kind:** note.

### L3 — `vmaBuildStatsString` under OOM was a null-deref crash (already fixed — keep it fixed)
**Evidence.** Run 45 crashed in `VmaJsonWriter` inside `reportVmaLayout`
(FINDINGS Run 45). It now uses `vmaCalculateStatistics` (`vk_utils.cpp:43-49`),
and the probe bisection is disabled. The image bisection (W3) is the one
remaining allocation-on-OOM path.

**Impact:** n/a (already fixed). **Risk:** regression if reintroduced.

---

## D. Ranked shortlist

1. **W1** staging pool (HIGH, larger) — biggest churn/fragmentation lever.
2. **M2** pre-warm a large VMA block at init (HIGH, measure-first) — targets the
   moving cap directly.
3. **M1** reconcile `preferredLargeHeapBlockSize` with the ledger (HIGH,
   measure-first/risk).
4. **W3** delete the OOM image bisection (MED, quick win) — stability.
5. **L1** `createImage` must not return a live image with a null view (MED,
   quick win) — leak class.
6. **W2** single staging buffer in the non-batch path (MED, quick win).
7. **W7** stop copying cached files on every hit (MED, larger).
8. **M4** byte-budget the DBC cache (MED, larger).
9. **M5** trim the file cache to the floor, not zero, on bad_alloc (MED, quick win).
10. **W4/W5/W6/W8** cleanup: dead attachment path, stale logs/comments, VMA
    strategy/budget flags (LOW, quick wins).
11. **M3** defrag at loading boundaries (MED, high risk — only with a drained
    boundary).

**Cross-cutting gate:** every recommendation that changes `preferredLargeHeapBlockSize`,
block sizing, or pools must be measured on hardware and its block ladder
(`probe: VMA stats` in `boot.log`) recorded in FINDINGS. A flag/allocator change
requires a clean `build-switch/` reconfigure (AGENTS.md) before the numbers mean
anything.
