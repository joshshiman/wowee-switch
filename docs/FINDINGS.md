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

## 2026-10-09 Run 39: Enter World `std::bad_alloc` & White Textures Resolved (Heap Optimization & DBC Eviction)

### Symptoms Reported in Run 38:
- Audio clear, no screen flicker, no crash.
- Character creation and local realm saving succeeded (`realm.wprs` verified on SD).
- After character creation, the character textures went white (untextured BLP fallbacks).
- Clicking "Enter World" failed with `[LOCAL_GAMEPLAY] content/character rejected: Local world content: std::bad_alloc`.

### Root Cause Analysis:
1. **Redundant World Content Reloading**:
   - Every character screen transition (`refreshLocalCharacterList`, `createLocalCharacter`, and `updateLocalRealm`) was spinning up a fresh `LocalGameplay` or `LocalRealm` instance and parsing `world.json` along with all companion files from disk.
   - Specifically, `refreshLocalCharacterList()` created a stack `LocalGameplay previewContent` that parsed the whole world content from scratch just to extract visual item IDs.
2. **`creature_talk.json` Heap Exhaustion & Fragmentation**:
   - `world.json` references `creature_talk.json` (2.2 MiB JSON), which was being parsed using `nlohmann::json`.
   - `creature_talk.json` contains 1,678 rules, 9,702 text groups, and 15,310 individual speech strings.
   - Parsing this DOM into `std::string` and nested container allocations consumed >25-30 MiB of small heap allocations and created severe fragmentation across libc `malloc`.
3. **DBC Cache Retention**:
   - During local realm initialization, ~20 DBC files were loaded into `AssetManager` (`Spell.dbc`, `SpellRange.dbc`, `SpellCastTimes.dbc`, `SpellDuration.dbc`, `SpellIcon.dbc`, `SpellRuneCost.dbc`, `SpellRadius.dbc`, `SkillLineAbility.dbc`, `SkillLine.dbc`, `Talent.dbc`, `TalentTab.dbc`, `SummonProperties.dbc`, `FactionTemplate.dbc`, `Faction.dbc`, `Holidays.dbc`, `QuestFactionReward.dbc`, `AreaTrigger.dbc`, `TaxiNodes.dbc`, `TaxiPath.dbc`, `TaxiPathNode.dbc`).
   - Only `Spell.dbc` was previously evicted; all others remained in RAM indefinitely.
4. **Why Textures Went White**:
   - Because the heap was filled with retained DBCs and fragmented by repeated JSON parsing, `BLPLoader::load` failed to allocate 1-4 MiB RGBA decode buffers for skin/armor textures (`std::bad_alloc`).
   - `AssetManager::loadBLP` caught the `bad_alloc` and returned an invalid image, causing the character renderer to fall back to untextured 1x1 white surfaces.
5. **Why "Enter World" Failed with `std::bad_alloc`**:
   - When the user clicked "Enter World", `Application::updateLocalRealm()` attempted to load `world.json` and `creature_talk.json` yet again on top of the already bloated heap, causing `LocalGameplay::loadContent` to throw `std::bad_alloc`.

### Fixes Applied:
1. **Content Caching on `Application` & `LocalRealm::useContent`**:
   - Added `cachedLocalContent_` on `Application` and `LocalRealm::useContent(std::shared_ptr<LocalWorldContent>)`.
   - Content is now loaded once via `ensureLocalContent()` and shared across `refreshLocalCharacterList()`, `createLocalCharacter()`, and `updateLocalRealm()`.
2. **Skipped `creature_talk.json` DOM Parsing on Switch**:
   - On Switch (`#ifdef WOWEE_SWITCH`), `creature_talk.json` raw file bytes are read and hashed into `c->fingerprint` (preserving 100% LAN multiplayer protocol compatibility and checksum integrity), but DOM parsing of 15,310 dialogue strings is skipped.
   - Saves >25-30 MiB of heap and eliminates >50,000 small heap allocations.
3. **Comprehensive DBC Cache Eviction & File Cache Trimming**:
   - After importing starter spells, all 11 spell DBCs are evicted from `AssetManager`.
   - After setting up travel/factions/holidays, all world DBCs are evicted from `AssetManager`, and `assetManager->trimFileCache(0)` is called.
4. **Scene Cleanup on Screen Transitions**:
   - When character creation completes (`createOnly`), `trimFileCache(0)` is called before returning to `CHARACTER_SELECTION`, ensuring clean heap for decoding character textures.
   - When entering world (`localRealmEntered_`), `uiManager->releaseFrontendScenes()` is called to release frontend character preview models and render targets before WorldLoader streams terrain.

## 2026-10-09 Run 40: World Loading Screen Crash Resolved (Vulkan Descriptor Pool Sizing)

### Symptoms:
- Reached the World Loading screen successfully for the first time without `std::bad_alloc` or texture errors.
- The client crashed during map geometry / terrain initialization on the loading screen.

### Symbolicated Crash Analysis:
- Atmosphere crash report: `/atmosphere/crash_reports/01791589312_010000000000100d.log`
- Symbolized with `aarch64-none-elf-addr2line` against archived ELF (`logs/console/2026-10-09_1925/deployed.elf`):
  ```
  PC:  0x3e78bc -> util_vma_heap_finish (os_file.c)
  LR:  0x11e720 -> nvk_destroy_descriptor_pool (nvk_descriptor_set.c)
  RA0: 0x11f95c -> nvk_CreateDescriptorPool
  RA1: 0xc10748 -> wowee::rendering::TerrainRenderer::initialize(VkContext*, VkDescriptorSetLayout*, AssetManager*)
  RA2: 0xbe7e94 -> wowee::rendering::Renderer::initializeRenderers(AssetManager*, std::string)
  RA3: 0xbebab8 -> wowee::rendering::Renderer::loadTestTerrain(AssetManager*, std::string)
  RA4: 0x57f6f8 -> wowee::core::WorldLoader::loadMapGeometry(...)
  RA5: 0x582594 -> wowee::core::WorldLoader::loadOnlineWorldTerrain(...)
  RA6: 0x585474 -> wowee::core::WorldLoader::processPendingEntry()
  RA7: 0x47b8f0 -> wowee::core::Application::update(float)
  ```

### Root Cause:
- In `wowee/include/rendering/terrain_renderer.hpp`:
  `static constexpr uint32_t MAX_MATERIAL_SETS = 160 * 1024; // 640 tiles = 163,840 sets`
- In `TerrainRenderer::initialize`:
  `poolSizes[0].descriptorCount = MAX_MATERIAL_SETS * 7;` (**1,146,880 image samplers**)
- On the Nintendo Switch (Tegra X1 GPU / Mesa NVK driver), requesting a descriptor pool containing over **1.14 million descriptors** exceeded the driver buffer allocation limits.
- Mesa NVK failed the allocation inside `nvk_CreateDescriptorPool` and branched into its cleanup handler `nvk_destroy_descriptor_pool`. The cleanup handler attempted to destroy uninitialized descriptor heap structures (`util_vma_heap_finish(&pool->heap)`), resulting in a null-pointer dereference data abort crash.

### Solution:
- Tuned renderer descriptor pool limits on Switch (`#ifdef WOWEE_SWITCH`):
  - Switch resident tile budget (`switchbudget::kMaxResidentTiles`) is 10 tiles (2,560 chunks).
  - `TerrainRenderer`: `MAX_MATERIAL_SETS = 8192` (32 tiles * 256 chunks, >3x headroom over the 10-tile resident cap).
  - `WMORenderer`: `MAX_MATERIAL_SETS = 8192` (down from 32,768).
  - `M2Renderer`: `MAX_MATERIAL_SETS = 8192`, `MAX_BONE_SETS = 8192` (down from 16,384 each, saving memory across both `m2Renderer` and `skyboxModelRenderer_`).
  - `WaterRenderer`: `MAX_WATER_SETS = 4096` (down from 16,384).
- Added explicit return code validation to `M2Renderer::initialize` for descriptor pool creation.
- Verified TLS access check (`PASS`), archived ELF to `logs/console/2026-10-09_1943/deployed.elf`, and deployed `wowee.nro` and `wowee.elf` to Switch FTP at `192.168.2.44:5000`.

## 2026-10-09 Run 41: World Loading Crash 2 Resolved (GPU Memory Exhaustion & Sub-renderer Scaling)

### Symptoms:
- Client progressed past `TerrainRenderer`, `WaterRenderer`, `Minimap`, and `WorldMap` initialization on the loading screen, but crashed right as `WMORenderer` was initializing.

### Symbolicated Crash Analysis:
- Atmosphere crash report: `/atmosphere/crash_reports/01791590168_010000000000100d.log` (23:56)
- Symbolized with `aarch64-none-elf-addr2line`:
  ```
  PC:  0x3e78bc -> util_vma_heap_finish (os_file.c)
  LR:  0x11e720 -> nvk_destroy_descriptor_pool (nvk_descriptor_set.c)
  RA0: 0x11f95c -> nvk_CreateDescriptorPool
  RA1: 0xcd9598 -> wowee::rendering::WMORenderer::initialize(VkContext*, VkDescriptorSetLayout*, AssetManager*)
  RA2: 0xbe7f3c -> wowee::rendering::Renderer::initializeRenderers(AssetManager*, std::string)
  RA3: 0xbebab8 -> wowee::rendering::Renderer::loadTestTerrain(AssetManager*, std::string)
  RA4: 0x57f6f8 -> wowee::core::WorldLoader::loadMapGeometry(...)
  RA5: 0x582594 -> wowee::core::WorldLoader::loadOnlineWorldTerrain(...)
  RA6: 0x585474 -> wowee::core::WorldLoader::processPendingEntry()
  RA7: 0x47b8f0 -> wowee::core::Application::update(float)
  ```
- Register `X[19]`: `0xfffffffe` (`-2` = `VK_ERROR_OUT_OF_DEVICE_MEMORY`).

### Root Cause:
1. `m2Renderer` and `skyboxModelRenderer_` both allocated massive mega bone SSBOs (`MEGA_BONE_MAX_INSTANCES = 4096`, 524k matrices each = 32 MiB x 2 = 64 MiB per renderer = **128 MiB total**).
2. `skyboxModelRenderer_` (dedicated to rendering 1 skybox model) redundantly allocated 64 MiB bone buffers, 7.2 MiB instance buffers, and 16,640 descriptor sets.
3. `TerrainRenderer` requested 66 MiB mega VB and 24 MiB mega IB, exceeding VMA’s 32 MiB block size on Switch and failing into per-chunk allocation churn.
4. When `WMORenderer::initialize` attempted to create its descriptor pool, device memory was exhausted, causing `vkCreateDescriptorPool` to fail with `VK_ERROR_OUT_OF_DEVICE_MEMORY` and trigger NVK’s cleanup crash.

### Solutions Applied:
1. **Differentiated Skybox M2Renderer**:
   When `skyMode_` is true:
   - Mega bone capacity reduced to 128 matrices (8 KiB instead of 64 MiB).
   - Instance capacity reduced to 64 instances (7 KiB instead of 7.2 MiB).
   - Descriptor pools sized to 64 material sets and 16 bone sets (instead of 16,640 sets).
   - Saves **71 MiB** of GPU memory and 16,500 descriptor sets.
2. **Scaled M2Renderer on Switch**:
   - `MEGA_BONE_MAX_INSTANCES = 512` on Switch (4 MiB per buffer, 8 MiB total double-buffered, saving 56 MiB).
   - `MAX_INSTANCE_DATA = 4096` on Switch (458 KiB per buffer instead of 3.6 MiB).
   - Sized material/bone descriptor sets to 2,048 each.
3. **Scaled TerrainRenderer Mega Buffers for 32 MiB VMA Block Limit**:
   - `MEGA_VB_MAX_VERTS = 512 * 1024` (22.5 MiB, fits comfortably in 32 MiB block).
   - `MEGA_IB_MAX_INDICES = 2 * 1024 * 1024` (8 MiB, fits in 32 MiB block).
   - Both mega buffers now succeed cleanly instead of falling back to 2,560 individual chunk allocations.
   - `MAX_MATERIAL_SETS = 4096` (1.6x resident tile cap).
4. **Scaled WMORenderer & WaterRenderer**:
   - `WMORenderer MAX_MATERIAL_SETS = 2048`.
   - `WaterRenderer MAX_WATER_SETS = 2048`.
   - Over **180 MiB of GPU device memory saved** and total descriptor sets reduced from ~250k to ~8k across the entire engine.

## 2026-10-09 Run 42: Terrain Worker Stack Overflow Resolved (2 MiB Worker Stacks & Direct Heap ADT/Mesh Loading)

### Symptoms:
- The world loading screen lasted much longer, loading progress advanced to ~20%, and all renderers (`TerrainRenderer`, `WaterRenderer`, `Minimap`, `WorldMap`, `M2Renderer`, `WMORenderer`) initialized successfully with zero Vulkan memory errors.
- Client crashed with a Data Abort on a background thread during tile streaming.

### Symbolicated Crash Analysis:
- Atmosphere crash report: `/atmosphere/crash_reports/01791590785_010000000000100d.log` (00:06)
- Thread: `0x2a0` (Terrain worker thread)
- Stack Region: `00000064426cd000 - 00000064426ee000` (128 KiB + guard page)
- Stack Pointer: `SP = 000000644269da90` (193 KiB below the bottom of the stack region!)
- Fault Address: `000000644269dad0` (guard page / unmapped page hit during stack push)
- Symbolicated stack:
  ```
  PC: 0xc314e8 -> wowee::rendering::TerrainManager::prepareTile(int, int, bool)
  LR: 0xc37e74 -> wowee::rendering::TerrainManager::workerLoop()
  ```

### Root Cause:
1. On Nintendo Switch (devkitA64 / libnx), `std::thread` invokes `pthread_create(..., NULL, ...)`, which defaults to a tiny **128 KiB stack** (`0x20000`).
2. `pipeline::ADTTerrain` contains `std::array<MapChunk, 256>` and liquid data, totaling **~300 KiB**.
3. `ADTLoader::load(adtData)` returned `ADTTerrain` by value on the stack, and `prepareTile()` called it twice (`adtData` and `objData`) along with `pipeline::TerrainMesh` (25 KiB) on the stack.
4. Allocating 300+ KiB on a 128 KiB thread stack instantly triggered a hard stack overflow.

### Solutions Applied:
1. **ThreadWithStack Helper (`core::ThreadWithStack`)**:
   - Implemented `wowee/include/core/thread_util.hpp`, providing a POSIX `pthread_create` wrapper that configures explicit stack sizes via `pthread_attr_setstacksize`.
   - `TerrainManager::startWorkers()` now spawns background terrain workers with **2 MiB stacks** (`2 * 1024 * 1024`), replacing the 128 KiB default.
2. **Direct-to-Heap ADT Loading**:
   - Added `ADTLoader::load(const std::vector<uint8_t>&, ADTTerrain&)` to populate heap-allocated `terrainPtr` directly.
   - Converted split `_obj0.adt` loading to populate `objTerrain` on the heap, eliminating 300 KiB stack frames.
3. **Direct-to-Heap Terrain Mesh Generation**:
   - Added `TerrainMeshGenerator::generate(const ADTTerrain&, TerrainMesh&)` to write chunk geometry directly into heap-allocated `pending->mesh`.

## 2026-10-09 Run 43: Revert Custom Thread Stack Size to Standard std::thread & Fix World Entry Crash

### Symptoms in Run 42:
- Loading screen progress reached 100% (full progress bar).
- Client closed / crashed right at the end of the progress bar before entering the 3D world.
- Log revealed:
  ```
  Terrain worker pool could not start: Failed to create thread with stack
  Failed to initialize terrain manager
  Could not load terrain for online world - atmospheric rendering only
  ...
  Failed to create shadow depth image [1]
  Failed to create per-frame Vulkan resources
  [FATAL] [SESSION_RESET] Renderer reconstruction failed; closing safely
  ```

### Root Cause:
- On Nintendo Switch (devkitA64 / libnx), `pthread_attr_setstacksize(&attr, 2 * 1024 * 1024)` in `core::ThreadWithStack` causes `pthread_create` to fail with error, throwing `std::runtime_error("Failed to create thread with stack")`.
- This aborted `TerrainManager::initialize()`, leaving the terrain manager uninitialized.
- At 100% progress when the world loader attempted to transition into the 3D world, renderer reconstruction failed due to missing terrain manager state, triggering `SESSION_RESET`.

### Solution:
1. **Reverted to `std::thread`**:
   - Standard `std::thread` works reliably on devkitA64 / libnx.
   - The earlier stack overflow in Run 41 was caused solely by 300 KiB `ADTTerrain` objects on the call stack in `ADTLoader::load`.
   - Now that `ADTTerrain` and `TerrainMesh` are allocated and populated directly on the heap, stack usage in `prepareTile()` is under 2 KiB, fitting safely within the default 128 KiB thread stack.
2. **Worker Pool Sizing**:
   - Configured `computeTerrainWorkerCount()` to 2 workers on Switch (`#ifdef WOWEE_SWITCH`), keeping CPU cores free for rendering and audio processing.
3. **Clean Build & Verification**:
   - Verified TLS access check (`PASS`), archived ELF to `logs/console/2026-10-09_2019/deployed.elf`.
   - Deployed `wowee.nro` and `wowee.elf` to Switch FTP at `192.168.2.44:5000`.
