# Findings ledger — wowee-switch hardware porting

Everything here was measured on the console at `192.168.2.44`. This file exists
so that measurements are not repeated and ruled-out theories are not re-tried.
Read it before debugging a new symptom.

Last updated: 2026-10-09.

---

## 1. The console environment (verified, stable)

| | |
|---|---|
| Console | `192.168.2.44`, FTP port **5000**, anonymous |
| FTP server | mtheall `ftpd` homebrew (`/switch/ftpd/ftpd.nro`), not sys-ftpd |
| Atmosphere | 1.9.x |
| GPU | `NVIDIA Tegra X1 (NVK gm20b)` |
| Vulkan API | 1.3.305 reported by VMA |
| Memory types | **1** — `HOST_VISIBLE \| HOST_COHERENT \| HOST_CACHED`. **No device-local type exists.** |
| Memory heaps | **1** — `size=2415919104`, `flags=0x1` (DEVICE_LOCAL) |
| Heap budget | ~1843 MiB (from `VK_EXT_memory_budget`) |
| `maxMemoryAllocationCount` | 4096 |
| VMA version | 3.4.0, built with `VMA_STATS_STRING_ENABLED` |

**The console's filesystem clock runs ~4 h ahead of the client's log clock.**
Every crash and fatal report maps one-for-one onto a run in `boot.log` at
exactly `FS mtime − 4 h`. Always interpret mtimes with that offset.

**The card's `data/` directory is ignored by the running title.** `appRoot()`
resolves to the embedded romfs, so `sdmc:/switch/wowee/data` is inert while the
`.nro` carries a romfs. Changing an asset on the card does nothing; rebuild the
`.nro`.

---

## 2. The memory ceiling — measured, and it moves

This is the single hardest problem in the port. It is **not** a fixed limit.
Measured ceilings for the largest allocation the heap would serve, in order:

| Run | Measured ceiling | Note |
|---|---|---|
| 9 | 1,166,462 – 1,169,065 B | first bisection |
| 10 | 867,155 – 869,757 B | dropped 292 KiB |
| 14 | 518,400 – 520,875 B | dropped again |
| 17 | 731,818 – 898,388 B | recovered |
| 23 | image: 256×128 (131,072 B) | 512×256 refused |
| 25 | image: 128×128 (65,536 B) | 256×256 refused |

**A 65,536-byte image was refused in run 25 while 128×128 — the same 65,536
bytes — was served by the probe that ran immediately afterwards.** That is the
key fact: the heap was not short of room, it was full for an instant.

### What this ruled out

- **Not exhaustion.** The driver reports 1843 MiB budget with ~104 MiB live
  (184 buffers / 70 MB, 40 images / 34 MB).
- **Not `maxMemoryAllocationCount`.** The limit is 4096; ~224 allocations are
  live.
- **Not a static per-allocation cap.** The ceiling moves between runs, and a
  size refused in one run is served in the next.
- **Not VMA block sizing alone.** VMA's blocks come out as a fallback ladder
  (`32, 32, 16, 16, 8, 8, 4` MiB), so the driver will not reliably serve the
  32 MiB block VMA prefers. `preferredLargeHeapBlockSize` is set to 32 MiB.
  **8 MiB broke the M2 transfers** — do not go lower.

### What the VMA layout dump shows at failure

```
blocks=26  blockBytes=121.5 MiB  allocs=231  unusedRanges=40
largest unused range = 13,632 bytes
block sizes: [32, 32, 16, 16, 8, 8, 4] MiB
```

26 blocks, 121.5 MiB, and the largest gap in them is 13 KiB. So the allocator
is full of *small* holes while the heap reports gigabytes free.

---

## 3. The fixes, and why each exists

| Fix | Why |
|---|---|
| `-ftls-model=local-exec` | devkitA64 g++ 16.1.0 emitted `ldr w0, [x0, x0]` for **423** `thread_local` sites — reading `2 × TP`, no relocation to fix it. Instant abort at startup. Guarded by `tools/switch/verify_tls_access.py`. |
| Audio pre-wait removed | `audoutPlayBuffer` already blocks and harvests; the extra wait timed out after 1 s and miniaudio killed the device after one grain. |
| ImGui host-visible fallback | No device-local type exists, so `DEVICE_LOCAL` requests returned `0xFFFFFFFF`, which `nvk_AllocateMemory` used as an array index. Fault at `base + (-1<<3) + 6296`. |
| `preferredLargeHeapBlockSize = 32 MiB` | VMA's default 256 MiB is never served. 8 MiB fragments the pool below what M2 transfers need. |
| `main()` uses `_Exit` | `exit()` walks every open `FILE` via `_fwalk_sglue`; one is corrupt and aborts at `0x18` *after* `shutdown` is logged — which makes a clean exit look like a fresh crash. |
| Logger leaked singleton | Its static destructor ran after the C++ runtime had torn down the stream, aborting in `_close_r`. |
| Reclaim-and-retry | On allocation failure, drain completed upload batches (their staging is exactly the memory that was just freed) and try once more. |
| `sInstance_` before `createAllocator` | Without this the reclaim callback read null and the retry never ran. |
| Chunked staging (256 KiB) | A 1,398,100 B staging buffer crossed the ceiling. Chunks are now 256 KiB, under every measurement. |
| Static mip scratch | A per-texture `std::vector` of the full mip chain churned the heap; reused scratch removes it. |
| MPQ probe gate | `queryAvailableCpuMemory()` allocates a 512 MiB ladder per call and was being run **per archive** — 18 × ~2.5 s. Now gated behind the 48 MiB static ceiling. |

---

## 4. Bugs found in my own fixes (do not reintroduce)

- **Retry was dead code** — `createBuffer` registered a reclaim callback that
  read `globalInstance()`, but `sInstance_` was assigned *after*
  `createAllocator`. Fixed by moving the assignment earlier.
- **Slicing used the wrong call path** — `uploadBuffer` was taught to slice, but
  `m2_renderer` builds vertex data and goes through it, while the *texture*
  path makes its own staging and was untouched. Fixed by moving the slicing into
  `uploadBytesChunked` and routing all three callers through it.
- **Deferred-capture order** — `deferStagingCleanup(buf)` zeroes `buf`, and the
  slice loop read `s.buf.buffer` on the *next line*, so it recorded a copy from
  `VK_NULL_HANDLE`. Capture before deferring.
- **Mip scratch before the try** — `mipScratch.resize()` sat outside the
  try/catch, so its `bad_alloc` surfaced as a bare error with no texture named.
- **Per-texture mip vector** — a fresh `std::vector` of the whole chain per
  texture was a regression that fragmented the heap, and was itself the cause
  of a `bad_alloc`.

---

## 5. The hardware loop

Full commands in [AGENTS.md](AGENTS.md). The shape:

```
build → deploy via FTPD → close & launch the title → reproduce
      → fetch boot.log + wowps.log + crash report → symbolize → iterate
```

- Logs: `sdmc:/wowps/wowps/logs/{boot,wowps}.log`, appended across runs.
- Crash reports: `/atmosphere/crash_reports/` (a new one per crash).
- **Symbolize with the ELF that built the deployed `.nro`** — offsets are
  meaningless otherwise. A build whose source is unchanged since the previous
  deploy produces an identical binary, so `md5` compares confirm this.
- `tools/switch/verify_tls_access.py <elf>` guards the TLS fix.

---

## 6. Where the port actually is

**Verified on hardware:** boot, romfs mount, resource-root resolution, renderer
init with every pipeline, all 18 client MPQs open (2.9 GB `common.MPQ` included),
FrameXML addons, login logo and UI text, music playing. Clean exit.

**Blocked:** the character-creator scene. Every failure there is memory
allocation in the Vulkan texture path.

**Never run:** character creation completing, login, world load, in-game
rendering. This is the largest unknown and where the next real finding will be.

**Context that matters:** the user is targeting **single-player (local realm)**.
Local-realm content (`assets/local_realm`, 26 MB on disk) is *not* loaded in
these runs — zero `Content loaded` lines in `boot.log` — so it is not a factor
in the current crashes.
