# Findings ledger — wowee-switch hardware porting

Everything here was measured on the console at `192.168.2.44`. This file exists
so that measurements are not repeated and ruled-out theories are not re-tried.
Read it before debugging a new symptom.

Last updated: 2026-10-09 (evening — flashing/crash/audio session).

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

---

## 7. The 2026-10-09 evening session: flashing, character-select crash, audio

Everything in this section was measured from the run ending 17:36:48–17:37:00
(build `31e6981`, md5 `2682a265b03a5574ff38ca3e365d2338` — verified against the
card) plus the crash/fatal report directory.

### The crash itself: not a segfault, a device-lost exit

`wowps.log` ends:

```
17:37:00.942 [ERROR] endFrame[186] vkQueueSubmit FAILED: -4
17:37:00.944 [ERROR] GPU device lost - exiting application
17:37:01.082 [WARN ] [SHUTDOWN] Asset degradation: 22 read(s) lost ...
```

No wowee crash report exists and none can: wowee runs as an anonymous NRO inside
the hbloader/qlaunch applet process, so Atmosphere cannot attribute its frames.

### The paired crash reports are teardown noise, not the crash

Every run that *dies* produces, 1 s after its last boot.log line, a pair of
reports: process `hbloader` (`010000000000100d`, module `nx-hbmenu`, main thread
aborting in hbmenu code — a *fresh* hbmenu relaunch, entry stub at +0xc4 on the
stack) and process `qlaunch` (`0100000000001000`, LibraryAppletThread break).
Runs that end cleanly (HOME → close, e.g. run 10 at 22:32) produce **no**
reports. Calibration: report filename epoch − exactly 4:00:00 = the run's last
boot.log timestamp, one-to-one, across all 23 reports on the card. Do not
re-derive this; grep the run's end time instead.

Attempts to symbolize `nx-hbmenu + 0x…` or qlaunch `[4f8977c6] + 0x…` offsets
against `wowee.elf` produce garbage (verified by disassembly: no `brk` at the
crash PCs; qlaunch's module range is 12.0 MiB, smaller than wowee's `.text`
alone at 17.7 MiB). Those reports are the applet host's aftermath, full stop.

### The white flashing: a swapchain rebuild storm, ~14/s

`boot.log` shows `gpu: swapchain acquire FAILED` every third acquire, and
`wowps.log` shows `Frame synchronisation reset after a rebuild` 81+8 times per
run — every failure was `VK_ERROR_OUT_OF_DATE_KHR` (the silent path; zero
`Failed to acquire swapchain image` errors, so never VK_TIMEOUT, and the
failures are immediate — ~14/s rules out the 2 s acquire timeout). Each
OUT_OF_DATE triggered `recreateSwapchain`, which on Switch destroys and
recreates VideoOut (the layer flashes off/on — white, not black, because the
post-rebuild scanout images are fresh/never-written). After ~90 such cycles the
run 35 submit failed with DEVICE_LOST.

The failure count tracks reaching the glue/3D scene across every run since the
port first reached the main loop (92–451 failures per run; short runs that die
in boot show 0). It is not a regression of the VMA block-size commits.

### The mechanism, from the nxvk source (`wsi_switch.c` + libnx `native_window.c`)

- nxvk's WSI hands out **one checked-out buffer at a time**: `nwindowQueueBuffer`
  and `nwindowCancelBuffer` both *require* `slot == nw->cur_slot`, and the
  swapchain's `queue_present` clears `dequeued_slot` unconditionally.
- wowee's **deferred present** parks one image per frame and presents it one
  frame later — the only workflow that asks this WSI to hold two images across
  a frame boundary. The first acquire failure in run 35 is the first acquire
  after a park.
- The driver always creates exactly 3 images (`WSI_SWITCH_IMAGE_COUNT` is
  hardcoded, `minImageCount` in the request is ignored), so wowee's two-image
  fallback can never engage and `deferredPresent` was always on.
- What could *not* be pinned down statically: which exact code path returns the
  OUT_OF_DATE (the immediate candidates in `wsi_switch_dequeue_nonblocking` are
  `slots_configured == 0` or the dimension check in `wsi_switch_window_error`;
  the single-slot collision paths return VK_TIMEOUT or SURFACE_LOST, neither of
  which was observed). The exact acquire rc is now breadcrumb-logged
  (`gpu: swapchain acquire FAILED rc=…`) so the next run answers this.

### Fixes deployed 2026-10-09 ~18:05 (md5 `b6cec6abcc251a9b92e9ddfbd8b2fafa`)

1. **Deferred present off by default on Switch** (`WOWEE_VK_DEFER_PRESENT=1`
   re-enables). The synchronous present path (acquire → submit → present the
   image that is still checked out) matches the driver's state machine exactly.
2. **OUT_OF_DATE guard**: before rebuilding, the surface caps are re-queried;
   if the extent is unchanged the frame is skipped instead, with a growing
   threshold (5 → 10 → 20 … capped 120) that forces one real rebuild in case
   something non-extent changed. A successful acquire resets the patience.
   Result: worst case is a brief stall showing the last presented frame, not a
   VideoOut destroy/create storm.
3. **Audio breadcrumbs**: `audio: audout context open`, `audio: device init ok`,
   `audio: device start ok`, `audio: engine initialized (device started|NOT
   started)` — all boot-stage lines, so they always land in `boot.log`.

### Audio: one working run ever, and why it was invisible

`audio: first device write` appears in exactly one run in the whole boot.log
(10-08 22:43:19 — the same run that first recorded a 3D composite). Every other
run: `music started` but no device write, while SELF-TEST says `audio=ok`
(that verdict only means `ma_engine_init` succeeded). The old breadcrumbs could
not distinguish device-not-started from device-thread-stalled; the new ones
can. Runs 10 and 11 used the same build, so the failure is nondeterministic —
prime suspects are heap state at device-thread creation or a thread stall
between start and the first `onDeviceWrite`.

### Memory: the ceiling collapsed further

Run 35's self-test probe measured the allocation cap at **342,867–345,086 B**
(down from 518 KB–1.1 MB in runs 9–17). Consequences measured in the same run:
`Texture mip upload: staging failed: std::bad_alloc (totalSize=349524,
scratch=1398100)` — the *chunked* (256 KiB) uploader failed, meaning even a
256 KiB staging buffer could not be served: VMA's existing blocks are full of
≤13 KiB holes and any new block needs a fresh `vkAllocateMemory` above the cap.
`Login glue: exception during preparation: std::bad_alloc` followed, and 22
asset reads were lost to allocation failure. This is blocker 6's territory.

### Open questions this session leaves

- The exact nxvk path returning OUT_OF_DATE (next run's rc breadcrumb answers).
- Whether the device-lost submit disappears once the rebuild storm is gone
  (likely — no submit should ever race a VideoOut destroy again).
- Where the audio device thread stalls (next run's breadcrumbs answer).
- Why the driver caps `vkAllocateMemory` at ~343 KB while reporting a 1.8 GiB
  budget — the root disease of the port (blocker 6).

## 2026-10-09 Run 36: Frame-0 Instant Crash Resolved (md5 55909e59...)

### What happened on Run 35 deployment (instant crash on startup)
- Log: `[2026-10-09 18:22:21] ImGui Vulkan resource creation failed: -4`, `fatal: startup error`.
- Root cause:
  1. SDL posts an initial `SDL_WINDOWEVENT_RESIZED` during startup with `(1280, 720)`.
  2. In `application.cpp`, this called `window->getVkContext()->markSwapchainDirty()` unconditionally.
  3. In `renderer->beginFrame()`, this triggered `recreateSwapchain()`, destroying and remaking `overlayRenderPass` and the VideoOut swapchain layer.
  4. ImGui's pipeline was never rebuilt after render pass recreation.
  5. ImGui's `CheckVkResultFn` in `ui_manager.cpp` had `#ifdef WOWEE_SWITCH if (err < 0) throw std::runtime_error(...)`, causing an unhandled exception instead of graceful failure handling.

### Fixes Applied:
1. **Ignored window resize on Switch** (`application.cpp`): Handheld and docked Switch resolutions are fixed at 1280x720. SDL resize events never mark swapchain dirty on Switch.
2. **Recreate ImGui pipeline on swapchain rebuild** (`vk_context.cpp`): Called `ImGui_ImplVulkan_CreateMainPipeline` after `createOverlayRenderPass()` so ImGui always uses the current render pass.
3. **Removed hard throw in ImGui error callback** (`ui_manager.cpp`): Logged errors without throwing, allowing ImGui internal fallbacks to operate as designed.

## 2026-10-09 Run 37: White Flashing & Audio Fix Verified + Login Scene Fallback (md5 bff7fe77...)

### Key Learnings Documented (Run 36 verification):
1. **White Flashing Eliminated**:
   - The white flashing was caused by repeated swapchain/VideoOut destroy-and-recreate cycles triggered by `VK_ERROR_OUT_OF_DATE_KHR`.
   - Disabling deferred present eliminated the out-of-date acquire condition: nxvk's native WSI expects only 1 checked-out buffer at a time. Synchronous present matches this design directly.
   - All frame acquires in Run 36 reported `gpu: swapchain acquire done rc=0` with zero acquire errors or VideoOut churn.
2. **Audio Clear & Operational**:
   - Audio is now stable and fully working through `audout` hardware with 48 kHz stereo s16 buffers.
3. **Character Selection Screen State**:
   - The 3D scene composite (`UI_Human.m2` Stormwind room) rendered cleanly at 1280x720 without errors.
   - The middle of the screen was empty because **0 characters currently exist on the account/realm** (`characters.empty() == true`).
   - The UI correctly displays the prompt: *"You have no characters on this realm. Create a new character to begin your adventure."* along with the **Create New Character** button.
   - Creating a character will load and display the full 3D character model on the pedestal.
4. **Login Screen Background Fix** (Run 37):
   - The login screen previously had no background because `UI_MainMenu_Northrend.m2` (Icecrown Citadel + Sindragosa dragon) requests >20 large uncompressed BLP textures (~100 MiB), which exceeded the shared process heap budget and threw `std::bad_alloc`.
   - On Switch, `AuthScreen` now defaults to the Classic Dark Portal (`Interface\Glues\Models\UI_MainMenu\UI_MainMenu.m2`), which is compact (~10 MiB) and loads cleanly.
   - Added automatic fallback to Classic UI_MainMenu if any expansion scene fails to allocate.

## 2026-10-09 Run 38: Local Realm Save Failure Resolved (md5 562243d4...)

### Problem:
- Upon character creation or Enter World, the client reported:
  `"Local realm save failed; check free space and directory permissions"`.
- The user had 12 GB of free space on the SD card, so space was not the issue.

### Root Cause:
1. **Hardcoded PS4 directory paths on Switch**:
   In `application_local_realm.cpp`, `localSaveDirectory()` and `localContentPath()` had:
   `#ifdef WOWEE_SWITCH return "/data/wow_ps/saves/local_realm";`
   On Switch, the root filesystem `/data` does not exist. All writable storage on Switch lives under `sdmc:/wowps/wowps`.
   Attempting to open `/data/wow_ps/saves/local_realm/realm.wprs.new` returned `ENOENT`.
2. **FAT32 rename & fsync constraints**:
   - In `local_realm.cpp`, `copyFileBytes` and `atomicWrite` called `::fsync(fileno(f))`. On devkitA64 / newlib FAT filesystem, `fsync` is not implemented and fails.
   - On FAT32 SD cards, POSIX atomic `rename()` over an existing file fails unless the destination file is unlinked first.

### Fixes Applied:
1. **Corrected Save & Content Paths** (`application_local_realm.cpp`):
   - Changed `localSaveDirectory()` on Switch to `platform::switchport::writableRoot() + "/saves/local_realm"` (`sdmc:/wowps/wowps/saves/local_realm`).
   - Changed `localContentPath()` on Switch to check `platform::switchport::writableRoot() + "/realm/world.json"` before falling back to asset bundles.
2. **Hardened FAT32 Atomic Writes** (`local_realm.cpp`):
   - Excluded `::fsync()` on Switch (relying on `std::fflush` and fclose).
   - Ensured destination files are removed before `std::rename()` to support FAT32 filesystem semantics.
   - Updated `world.json` search paths on Switch to check writable root, app root, and romfs.
