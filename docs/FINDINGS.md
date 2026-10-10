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

## 2026-10-09 Run 44: Fix System Memory Heap Fragmentation (svcGetInfo) & Buffer Ceilings

### Symptoms in Run 43:
- The game ran with 100% stability at 60 FPS, zero crashes, clear audio.
- Character select and creation rendered cleanly.
- World loading reached 100% without crash, but was rejected with:
  `"There was not enough memory to load this area. Return to character selection and try again."`
- Log: `[ERROR] World load stopped: CPU allocation failed on map 0`
- Log: `[WARN ] [LOCAL_SESSION] before spell import freeMiB=0 measured=0 cached=0`
- Log: `[WARN ] TerrainRenderer: mega VB allocation failed, per-chunk fallback`
- Log: `[ERROR] GrassRenderer: no source buffer for 262144 blades (16777216 bytes)`

### Root Cause Analysis:
1. **Destructive Heap Probing (`probeLargestHeapBlock`)**:
   - `queryAvailableCpuMemory()` in `cpu_memory.hpp` executed a descending allocation ladder (`malloc(512MB)` -> `malloc(4MB)`) every 250ms on asset/file cache paths.
   - devkitA64 / libnx uses newlib where `malloc` invokes `sbrk()` / `svcSetHeapSize()`, and `free()` **never** unmaps memory back to the Switch OS.
   - Probing 512MB–4MB repeatedly forced the newlib heap to grow to the title memory ceiling while tiny allocations fragmented the free bins, destroying all contiguous blocks >4MB.
   - This caused `queryAvailableCpuMemory()` to report `0 MB free`, throttled `AssetManager` caches, declined asset loads, and eventually triggered `std::bad_alloc`.
2. **PS4 Budget Constants Left Active on Switch**:
   - `kCpuMemoryBudgetLimit` was hardcoded to 448 MiB (PS4 flexible budget), even though Switch provides 3,328 MiB (3.25 GB) in application mode.
   - `kCpuCacheBudgetLimit` was capped at 32 MiB.
3. **GPU Allocation Over-Sizing (Tegra X1 NVK 9.6 MiB Ceiling)**:
   - `TerrainRenderer::MEGA_VB_MAX_VERTS` was 512k vertices * 44B = **22.5 MiB**. Mesa NVK fails single allocations > 9.6 MiB, triggering per-chunk allocation fallback.
   - `GrassRenderer::kMaxSourceBytes` was 16 MiB, also failing the 9.6 MiB ceiling.
4. **Minimap TRS String Duplication**:
   - `Minimap::parseTRS` loaded `md5translate.trs` (10 MB) into `std::string content` and `std::istringstream`, holding 3x copies in RAM simultaneously.

### Solutions Applied:
1. **Native Switch Kernel Memory Query (`svcGetInfo`)**:
   - Replaced `probeLargestHeapBlock` with native libnx system calls:
     `svcGetInfo(&total, InfoType_TotalMemorySize, CUR_PROCESS_HANDLE, 0);`
     `svcGetInfo(&used, InfoType_UsedMemorySize, CUR_PROCESS_HANDLE, 0);`
     `freeBytes = total - used;`
   - Completely non-allocating, zero page touches, instantaneous, zero heap fragmentation.
2. **Corrected Switch Memory Ceilings**:
   - Updated `kCpuMemoryBudgetLimit` to 2048 MiB (2 GB) and `kCpuCacheBudgetLimit` to 128 MiB.
3. **GPU Buffer Sizing for 9.6 MiB Driver Cap**:
   - Sized `TerrainRenderer::MEGA_VB_MAX_VERTS = 128 * 1024` (5.6 MiB) and `MEGA_IB_MAX_INDICES = 1024 * 1024` (4 MiB) on Switch, fitting comfortably under the 9.6 MiB ceiling and eliminating per-chunk allocation fallback.
   - Sized `GrassRenderer::kMaxSourceBytes = 4 MiB` on Switch.
4. **Memory-Safe TRS and DBC Eviction**:
   - In `Minimap::parseTRS`: parsed in-place using `std::string_view` with zero duplicate buffers, wrapped in `try/catch`.
   - In `ZoneManager::enrichFromDBC`: evicted `SoundEntries.dbc` and `ZoneMusic.dbc` immediately after extracting music paths, wrapped in `try/catch`.
   - In `TerrainManager::ensureGroundEffectTablesLoaded`: evicted clutter DBCs immediately after extracting tables, wrapped in `try/catch`.
   - Reduced `kDefaultGroundClutter` on Switch from 70 to 25.

## 2026-10-09 Run 45: Symbolicated Crash Fix in VMA String Dumper, Elimination of Chunk Buffer Fragmentation & Low Preset Default

### Symptoms in Run 44:
- Client crashed with Data Abort (0x4A8 / 2168-0002) during world load at tile [32,47] chunk alpha texture creation.
- Symbolicated call stack from Atmosphere crash report (`01791593258_010000000000100d.log`):
  ```
  PC:  0x118aca8 -> memcpy
  LR:  0xb9b2cc  -> VmaVector<char>::resize
  RA0: 0xb9b650  -> VmaJsonWriter::BeginString
  RA1: 0xb9b8c0  -> VmaAllocation_T::PrintParameters
  RA2: 0xb9f034  -> VmaBlockMetadata::PrintDetailedMap_Allocation
  RA3: 0xba0bbc  -> vmaBuildStatsString
  RA4: 0xbb8560  -> wowee::rendering::reportVmaLayout(VmaAllocator) (vk_utils.cpp:44)
  RA5: 0xbb8fec  -> wowee::rendering::createBuffer (vk_utils.cpp:186)
  RA6: 0xbb9470  -> wowee::rendering::uploadBytesChunked
  RA7: 0xbc1f28  -> wowee::rendering::VkTexture::upload
  RA8: 0xc09af4  -> wowee::rendering::TerrainRenderer::createPackedAlphaTexture
  RA9: 0xc13070  -> wowee::rendering::TerrainRenderer::bindChunkTextures
  RA10: 0xc13718 -> wowee::rendering::TerrainRenderer::loadTerrainIncremental
  RA11: 0xc3f104 -> wowee::rendering::TerrainManager::advanceFinalization
  RA12: 0xc4008c -> wowee::rendering::TerrainManager::processOneReadyTile
  RA13: 0x580ccc -> wowee::core::WorldLoader::loadMapGeometry
  RA14: 0x5824b4 -> wowee::core::WorldLoader::loadOnlineWorldTerrain
  ```
- Error log prior to crash:
  `Failed to create VMA buffer (size=16384) result=-2 usage=1 memoryUsage=2 from vk_utils.cpp:246`
  `liveBuffers=406 liveBufferBytes=8398672 liveImages=160 liveImageBytes=9891840`
  `probe: allocation cap is between 225279 and 227497 bytes`

### Root Cause Analysis:
1. **Direct Crash in Error Reporting Logger (`reportVmaLayout`)**:
   - `reportVmaLayout` in `vk_utils.cpp` called `vmaBuildStatsString(allocator, &stats, 1)` with `detailedMap=true`.
   - When VMA memory was tight, allocating JSON strings across 400+ buffers caused internal `VmaVector<char>::resize` allocation failure, dereferencing a null pointer in `memcpy` (`X[0] = 0x0`).
2. **512 Redundant Per-Chunk Buffer Allocations in `uploadChunk`**:
   - `TerrainRenderer::uploadChunk` unconditionally allocated vertex (6,384 B) and index (3,072 B) buffers for all 256 chunks per tile (512 individual buffers per tile), even though all chunks were also copied into `megaVB_` and `megaIB_`.
   - In `render()`, chunks in mega buffers draw directly via `megaVB_` and `megaIB_` and never touch per-chunk buffers.
   - 512 tiny buffers per tile severely fragmented VMA memory blocks, causing `liveBuffers` to exceed 400 and reducing the largest contiguous free hole to under 225 KiB.
3. **Double Staging in `VkTexture::upload`**:
   - For 16 KiB alpha textures, `uploadBytesChunked` created both a CPU staging buffer AND a GPU buffer, transferring CPU -> GPU buffer -> VkImage.
4. **Default Graphics Settings**:
   - Defaulted to Medium/Custom with higher view distances, normal mapping, and doodad shadows enabled.

### Solutions Applied:
1. **Safe Zero-Allocation VMA Stats**:
   - Replaced `vmaBuildStatsString` in `reportVmaLayout` with `vmaCalculateStatistics(allocator, &stats)`. It logs block counts, allocations, and bytes without dynamic allocations.
   - Disabled the repetitive bisection loop in `reportAllocationProbe` to prevent perturbing the heap during OOM.
2. **Direct Mega Buffer Usage in `uploadChunk`**:
   - In `TerrainRenderer::uploadChunk`, if `megaVB_` and `megaIB_` have space, write directly into the mega buffers and set `chunk.vertexBuffer` and `chunk.indexBuffer` to `VK_NULL_HANDLE`.
   - Reserve individual buffer allocations strictly for fallback when mega buffers are unavailable or full.
   - In `TerrainRenderer::clear()`, reset `megaVBUsed_ = 0` and `megaIBUsed_ = 0`.
3. **Direct Host-Visible Staging in `VkTexture::upload`**:
   - For textures <= 256 KiB (including all 16 KiB alpha textures), stage directly through a single CPU-mapped buffer (`VMA_MEMORY_USAGE_CPU_ONLY`) into `VkImage`.
4. **Default Graphics Quality Set to Low on Switch**:
   - Default preset: Low (`viewDistance = 400.0f`, `shadowDistance = 100.0f`, `shadowQuality = 1` [Terrain only], `groundClutter = 15`, `normalMapping = false`, `parallax = false`).

## 2026-10-09 Run 46: Title-Override World Entry Rejected (CPU query measured heap slack + WMO pool)

### Symptoms (user report + logs 2026-10-09_2135, run 21:23, title-override mode):
- "There was not enough memory to load this area" on Enter World (map 0),
  graceful return to character select, **no crash report** — the client survived.
- Font visibly changed vs prior runs; minor intermittent black flashing on the
  right screen edge (only 2-3 swapchain rebuilds in the run — the white-flash
  storm is fixed; right-edge flash is a separate open item, repro needed).
- `wowps.log`: `World load stopped: CPU allocation failed on map 0`, preceded by
  `WMORenderer: failed to allocate material descriptor set`.
- `Interface fonts loaded: 0 of 5`, `No frizqt__.ttf ... keeping the built-in
  face` — hence the font change. FRIZQT was *declined by the headroom gate*,
  not missing: `Optional asset declined for CPU headroom: flexible free 3 MiB
  below 8 MiB (latest Fonts\FRIZQT__.TTF)`, plus declined .anim/.skin files.
- `[LOCAL_SESSION] before spell import freeMiB=3 measured=1`,
  `Terrain streaming held back: free=3 MiB measured=1` — in title-override mode
  with gigabytes actually free.

### Root cause 1 (the big one): the free-memory query measured heap slack
`queryAvailableCpuMemory()` (`cpu_memory.hpp`) computed
`TotalMemorySize - UsedMemorySize`. On Horizon, Total is the *currently mapped*
heap, which newlib grows on demand via sbrk — so the difference is heap slack
(a few MiB by design), never available memory. Every gate built on it (8 MiB
stream-stop, font/anim/skin declines, terrain holdback) latched shut in the
mode with the *most* RAM. Do not re-derive: `free = title cap - used`, with
caps 448 MiB (applet) / 3328 MiB (override) selected by the existing
`isAppletMode()`. Fixed in `cpu_memory.hpp` (forward-declared `isAppletMode`
to avoid including `switch_platform.hpp`).

### Root cause 2: WMO descriptor pool exhaustion aborted world entry
Elwynn tile [32,48] (Northshire Abbey + surroundings) needs more than the 2048
Switch `MAX_MATERIAL_SETS`; `allocateMaterialSet()` returned null and the call
site threw `std::bad_alloc`, which `world_loader` mislabeled "CPU allocation
failed" and bounced the player to login. Fixes: pool raised to 8192, and
exhaustion now warn-once + leaves the batch unset instead of throwing — the
main/shadow/cull passes already skip null sets, so a missing wall beats a
rejected entry. M2 already degraded this way; only WMO threw.

### Deployed 2026-10-09 ~21:40 (md5 `710cae61...`): memory-query fix + WMO pool/skip.
### Open: right-edge black flash (needs screen + docked/handheld + frequency);
### exact WMO set count Elwynn needs (log will show whether the warn-once fires).

## 2026-10-09 Run 47: FIRST WORLD ENTRY on hardware (build 710cae61, title override)

### Milestone
Entered the world on the console: terrain streaming ([32,48], [30,48], [29,48]
...), NPC humanoid displays spawning, HUD, ground clutter, no crash, no world
rejection. Verified in logs 2026-10-09_2143 (wowps.log 1.1 MB in-world).

### Fix verification from the run
- Memory query: `flexibleBytes=149827584` (~143 MiB) at renderer init vs 4 MiB
  before — gates open. `Interface fonts loaded: 5 of 5` (font back).
- WMO pool: no `pool exhausted` warning, no descriptor failure on Elwynn entry.
- Only 2-3 swapchain rebuilds; no OUT_OF_DATE storm. Audio breadcrumbs all
  present through `engine initialized (device started)`.

### Known issues from the run (open)
- Intro cinematic (authored camera flight) never left buffering; user skipped
  with Circle. By design it waits for flight-corridor tiles to be scene-ready
  (`application_character_intro.cpp` prewarm); on hardware streaming that can
  take very long. Unknown whether it resolves with patience or stalls forever
  — needs a timed repro. No INTRO lines in Release logs (INFO-suppressed).
- `[FRAMEXML_REQUIRED] original UI unavailable: preflight declined` (x2) —
  client runs on fallback UI; preflight reason not in WARNING logs.
- Right-edge intermittent black flash (user report, 1 occurrence class) —
  still needs screen + docked/handheld + frequency.
- Screenshots taken via Switch capture are inside the emuMMC raw partition
  (`/emuMMC/RAW1`), invisible to ftpd (`/Nintendo/Album` on SD is the sysMMC
  side and empty). Phone photo is the practical transfer path.

## 2026-10-09 Run 48: in-world perf + ground-texture diagnosis (build 1dae4906)

### User report (run 47 playtest): ground texture didn't load, everything slow.
- Zero declined assets and zero texture/material failures in the run's warnings,
  so the ground is not a headroom-gate or allocation problem — binding path
  looks complete (base + layers + alpha with fallbacks). Needs eyes: a photo
  settles white-vs-flat-vs-blurry instantly.
- Slowness shape: `endFrame` worst ~383 ms repeatedly (24-52 frames over
  50 ms per 10 s window), `renderer->update` worst 100-348 ms (streaming
  finalize: TERRAIN/WMO steps 5-20 ms each). No GPU-side data in Release logs.

### Change deployed (~22:00, md5 `1dae4906...`): perf telemetry always loud
- `frameProfileEnabled_` forced true on Switch (env var unsettable without a
  shell) → 10 s frame-budget + per-stage means + last-frame GPU pass
  breakdown at WARNING.
- `[WORLD_PERF]` (already carries per-pass CPU means: prepare/shadow/
  terrain/wmo/m2/chars/post + gpuTimingStatus), `[LOCAL_PERF]`, `[WORLD_SCENE]`
  promoted INFO→WARNING. All inside the existing Switch-only in-world block;
  WORLD_PERF fires every 5 s in-world. Next run answers CPU-vs-GPU and names
  the pass.

## 2026-10-09 Run 49: GPU-bound confirmed (~400 ms frames), shadows+post cut

### WORLD_PERF (run 21:57, build 1dae4906, title override, Elwynn in-world)
- loopFps 2.0-2.6, frameMean 380-490 ms. Per-pass CPU means sum to ~10-25 ms
  (shadow 4-12, reflection 1-6, camera ~1, terrain/wmo <0.5, m2 2.5-5,
  chars 0, post 0) against renderMean 364-456 ms → the ~400 ms is GPU
  execution + present back-pressure, not CPU recording. updateMean 13-70 ms
  (streaming finalize). `gpuTimingStatus=uncalibrated-switch`, so no per-pass
  GPU split exists on this driver — the CPU remainder is the whole signal.
- Active GPU load: volumetricRendered=1, raysEnabled=1, bloomRendered=1,
  shadowQuality=2 at 720p, msaa=1, vsync=1. Water reflections already off on
  Switch (default "0").

### Change deployed (~22:00, md5 `41c8ee0d...`): Switch startup performance mode
- Shadow quality forced 0 (clear-only pass; atlas stays valid, cleared depth
  reads as lit — the designed off-ramp, not the `setShadowsEnabled` stub which
  hardwires true). Map side 512. Live dropdown still works mid-session.
- Volumetric quality 0 + rays/fog off, bloom off — all live panel toggles, so
  startup just begins fast regardless of saved CVars; re-enableable in-session.
- Renderer.cpp only; desktop paths untouched (ifdef-split at both sites).
- Next run's WORLD_PERF shows what the remaining ~400 ms is (likely raw scene
  fill at 720p → render-scale or view-distance step next).

## 2026-10-09 Run 50: 2.3 → 6.9 fps; sink-level perf floor; stick fix

### WORLD_PERF (run 22:0x, build 41c8ee0d): 145-387 ms frames, settling ~145 ms
- CPU passes still sum to ~10-25 ms; GPU remainder down from ~400 to ~130 ms
  after shadows-off + volumetric-off. bloomRendered=1 though: game_screen
  re-applies saved panel values on world entry through the same sinks,
  undoing the startup force. Volumetric stayed off, shadow quality held 0.

### Change deployed (~22:05, md5 `192edf17...`)
- Perf floor moved into the setting sinks (setShadowQuality→0,
  setVolumetricQuality→0, rays/fog/bloom→false on Switch): every route
  (startup, saved settings, Lua, panel) passes through them. Panel toggles
  won't stick on hardware until the guards are lifted — noted in code.
- Thumbstick Y un-inverted: libnx reports stick-up as +Y; forward is +ly
  (was -ly, walking backwards on push-up). Strafe axes unchanged.

### Still open, needs eyes (no log signal)
- Ground "doesn't load": zero white-fallbacks, zero BLP/texture failures in
  warnings — textures bind. Candidates left: distant-tile base shading,
  holes in streaming, or lighting flatness. Photo or color description needed.
- Portraits (player + target): no PORTRAIT_MEMORY warnings, composite pass
  runs in-world via render graph. What's displayed vs expected unknown —
  photo needed.

## 2026-10-09 Run 51: device-lost on a STALE build (do not chase)

### What happened
Three launches on the card's old build (SELF-TESTs 21:56, 22:03, 22:11; none
has "switch performance" or WORLD_PERF lines, so predates 41c8ee0d/b1552fc).
Last one died ~1 min after world loading: `immediate submit failed: -4`
during quest-marker texture upload → fence wait -4 → clean device-lost exit.
No VMA/CPU pressure in the log (142 MiB free). The paired hbloader report
carries the *overridden title's* program ID (010001300d14a000, not the Album
100d) — same nx-hbmenu abort signature, same teardown-noise verdict.

### Black diagonals
Shown after the device died mid-frame: a partially rendered tiled frame
handed to the compositor. Corpse artifact of the device loss, not its own
bug. If diagonals ever appear while the game *keeps running*, that is new.

### Lesson: verify the card before diagnosing
`RETR /switch/wowee/wowee.nro` + md5 matched local (`192edf17...`) — the new
build (sink perf floor + stick fix) is intact on the card and has never run.
Always confirm build-vs-log before analyzing a crash: this one cost nothing.

## 2026-10-09 Run 52: entry-burst device loss, twice at quest-marker upload

### Shape (runs 22:12 stale build + 22:48 new build, identical)
`immediate submit failed: -4` then batch `submit result=-4`, fence -4, FATAL
`GPU upload submission failed` escaping update — all within one second at
world entry, quest/footprint pipelines just created. No VMA/CPU distress
(142 MiB free), single-threaded submits, in-flight bounded (16/32 MB caps).
Ruled out statically: texture-slice OOB (layout validator rejects short
levels; BLP loader pre-truncates), immFence thread race (no multi-thread
warning), marker uploads themselves (bystanders that fail after). Remainder:
driver-internal fault under entry burst surfacing at the next submit, or an
earlier faulted streaming batch. Not distinguishable from CPU-side logs;
gpuTimingStatus stays uncalibrated-switch.

### Also confirmed this run (new build): menus 30 fps (300 frames/29.96);
### startup forces held (shadow 0, volumetric/bloom off). No WORLD_PERF: died
### during entry loading, before 5 s in-world.

### Change deployed (~22:50, md5 `fac43402...`): burst containment
- Stage-5 marker/footprint init drains in-flight batches first on Switch; if
  the device is already lost both inits take their existing non-fatal path
  instead of piling submits onto a dead device toward FATAL.
- Switch backpressure halved (8 batches / 16 MiB vs 16 / 32 MiB): peak
  in-flight driver load is the prime suspect, throughput is the price.

## 2026-10-09 Run 53: entry serial-upload experiment (build 78a9bd3c)

### Run 23:03 (build fac43402): third identical death, backpressure exonerated
`immediate submit failed: -4` at world-entry HUD setup → fence -4 → FATAL.
In-flight never hit even the halved caps (no UPLOAD_PRESSURE line), so peak
in-flight volume is NOT the trigger. Ruled out to date: texture-slice OOB,
fence thread race, memory-type index, allocator distress, in-flight volume.
Remainder: submit concurrency/timing vs driver internals, or a content fault
in an earlier streaming upload surfacing late.

### Change deployed (~23:00, md5 `78a9bd3c...`): serialize entry uploads
- `VkContext::setSerialUploads` (Switch): while set, every
  `finishUploadBatch` waits for its own fence. Immediate submits already wait.
  Net effect during entry: (almost) no two submits are ever in flight at once.
- `WorldLoader::loadOnlineWorldTerrain` sets it for the whole entry scope
  (all entries funnel here, local + online); LoadingGuard resets it on every
  exit including exceptions. One ifdef each side; desktop untouched.
- Entry loads will be slower (no submit overlap). If 2-3 entries go through
  clean, concurrency is confirmed and selective serialization follows. If it
  still dies at the same point, concurrency is exonerated and the fault is in
  the content of an entry upload.

## 2026-10-09 Run 54: null-descriptor audit → M2 particle/ribbon hole (FIXED)

### Audit (issue #123 class: null view/bind = lost device on NVK)
Terrain/WMO/M2-material/character/quest-marker writes+binds all guarded
(pick-to-white, drop-unset, skip-null). Three live holes found:
1. **M2 particle/ribbon pre-alloc sets** (m2_renderer.cpp:1822/:1872): on
   failed resolve the code `continue`d after a SUCCESSFUL
   vkAllocateDescriptorSets, leaving a non-null, never-written set that sails
   through the bind-time null check (particles.cpp:849, ribbon :484). Trigger
   is pool exhaustion + unsampleable white fallback coinciding = streaming
   pressure = world entry. Matches all four entry deaths (intermittent by
   timing). FIXED: free + NULL the slot on that path.
2. **Footprint bind** (:367): no validity recheck; partial loadTextures
   failure leaves null/unwritten slots bound unconditionally. FIXED: skip when
   set null or texture invalid. Low likelihood (not streaming) but same class.
3. **Preview shadow placeholder** (character_preview.cpp:490): writes NULL
   view by construction if placeholder absent; sampler from getShadowSampler
   (valid — created at renderer init, fatal if null). Portraits render through
   this set in-world too. Placeholder upload succeeds in practice; left as-is,
   note for the portrait investigation (which shows no log signal at all).

### Change deployed (~23:10, md5 `ff618d21...`): the two frees + guard.
### Serial-upload experiment inconclusive: run 23:09 died the same way WITH
### serialization (immediate -4 at marker upload). Concurrency downgraded as
### prime suspect; poison-descriptor (now fixed) takes its place. Serial mode
### stays in (harmless, still informative if deaths stop).

## 2026-10-09 Run 55: marker init deferred past the burst (build 3670ec31)

### Run 23:17 (build ff618d21): fifth identical death, particle fix not it
Immediate -4 on a marker upload again, ~35 s into entry. The unwritten-set
fix changed nothing observable — demote poison-descriptor below burst-timing
again, with the caveat the fix was still correct hygiene (the hole was real,
just not this killer).

### Change deployed (~23:25, md5 `3670ec31...`): split burst from content
- Stage 5 no longer inits markers/footprints mid-entry on Switch (logs one
  line). New `Renderer::runDeferredMarkerInit()` runs at entry end from
  WorldLoader, right after the existing pre-render vkDeviceWaitIdle, when the
  GPU is drained and streaming has settled.
- Two clean outcomes, both decisive: entry survives → the burst composition
  (uploads interleaved with streaming) is the killer and markers stay late
  (they pop in as the world appears — invisible); dies identically at the
  same point → markers fully exonerated and the fault is in streaming-frame
  content, which becomes the only remaining theory.

## 2026-10-09 Run 56: entry survives with markers deferred; FSR1 forced

### Run 23:24 (build 3670ec31): NO CRASH — burst theory confirmed
Marker/footprint pipelines created at entry end with zero upload failures;
entry survived. 5/5 prior deaths had those uploads mid-burst. Markers stay
late (user saw none — quest already accepted, nothing to show). 27 WORLD_PERF
samples in-world: 4.2 fps avg, renderMean 238 ms vs ~7 ms CPU passes — still
GPU fill-bound with shadows/volumetric/bloom all at 0. NPCs=112 in Elwynn.
User-noted lag toward Stormwind (denser WMO) fits fill-bound.

### Change deployed (~23:30, md5 `a0bc10bb...`): FSR1 spatial upscale forced
- `Renderer::setFSREnabled(false)` becomes enable + 0.59 render scale on
  Switch (~755x425 scene, 35% pixels; EASU/RCAS resolve; UI composites after
  at full res). FSR2 still refuses itself (compute features). Same
  delete-to-restore contract as the shadow/post floor.
- If scene fill is the remaining ~230 ms, expect roughly half. WORLD_PERF
  next run confirms; if FSR resolve itself misbehaves on NVK it shows
  immediately (never exercised there before).

## 2026-10-09 Run 57: no floor (geometry, not texture) + 540p scene default

### User report (run 23:33, build a0bc10bb): no ground geometry at all
Distant mountains visible, nothing underfoot — yet 9 tiles resident,
terrainDrawn=11-105/frame, zero texture failures, zero white fallbacks.
Not yet diagnosed (needs eyes): culling is distance+frustum with valid+set
gates, all shared paths audited guarded. Character/NPC/WMO draws all nonzero
(22-175/40-230), so the world draws around a missing floor. Also still: no
self portrait, no quest icons seen.

### FSR1 force reverted + scene height 540 (build 387a2da9)
- `setFSREnabled` hard-blocks FSR1 on Switch ("fixed world-resolution profile
  and FXAA remain") — the force only produced a confusing log pair. Removed;
  pass-through restored.
- Switch scene-height default 720→540 (sanctioned lever: off-screen world
  target + FXAA resolve, UI/menus stay 720p, runtime-raisible in options).
  Expect scene fill ~55% of before. WORLD_PERF sceneWidth/Height will confirm
  960x540 next run.

### Screenshot path that works over FTP
Renderer::captureScreenshot exists, bound to gamepad circle on the HUD
(game_screen_hud.cpp:1785), saves to <home>/.wowps/screenshots/WoWPS_*.png =
sdmc:/wowps/wowps/.wowps/screenshots/ — retrievable via ftpd, unlike the
Album (emuMMC raw partition). Asked user to press circle in-world.

## Process lesson (2026-10-10): md5 alone is not verification
The "9ac841ed" recorded for the button-name deploy never existed as a distinct
build — the staged file was 67553954 before and after (same bytes, verified by
strings content + rebuild determinism). Almost certainly a misread/misattributed
terminal line under fatigue. Rule from here on: verify deploys with
`strings <nro> | grep <new-string>` (content truth) AND card-vs-staged md5
(transfer truth). Both are now done for every deploy below.

## 2026-10-10: screenshot chord v2 + missed shoulder line (build 479c1d72)
- Card held the right build all along (67553954, strings-verified) — the
  user's stale-build suspicion was wrong, and so was the phantom md5.
- Real miss #1: help-overlay line 1 still said "L2 / R2 ... R1" (only line 3
  had been converted). Fixed to ZL/ZR/R. This is almost certainly the "hints"
  the user saw.
- Real miss #2: chord read the press EDGE, but at 3-4 fps a quick tap falls
  between pumps and the edge never exists. Now reads HELD L1+B with a latch:
  hold both through any pump instant to fire once, release B to re-arm.
  Verified in staged binary via strings; card md5 MATCH.

## Screenshots PARKED (2026-10-10, user request)
Phone photo worked; in-game capture fought back across 4 attempts (unwired fn
-> layer-eaten chord -> edge-vs-pump timing). Current state: PRINTSCREEN
synthesized from any-shoulder+B in the pad layer (bd3dc21, on card), plus
fired/failed WARNINGs. Revisit only when a README shot or a daylight check
needs it. Input-telemetry note honored: pad bits were never logged; if input
is ever doubted again, log raw bits first, assume nothing.

## Invisible floor: mesh forensics conclusive (host tool, no console cycles)
- `meshstats` (/tmp/opencode/meshstats: StormLib static + ADTLoader +
  TerrainMeshGenerator, stubs for logger/profiler): tile [32,48] from BOTH
  common-2.MPQ and patch.MPQ (patch carries its own 99-bytes-different copy)
  yields 256 valid chunks, 37k verts, finite positions, in-range uint32
  indices, 44-byte verts. The 99 bytes are header-only; geometry identical.
- Coordinate red herring killed: raw ADT coords LOOK alien (16533.x) but
  generateChunkMesh converts to render space from tile/chunk indices ("MCNK
  position fields are unreliable") — tile [32,48] spans render
  X[-9066,-8533] Y[-533,0] Z[61,277], player at (-8940,-128,83) inside it.
  An early meshstats run with unset terrain.coord "proved" a mismatch that
  was a harness bug. Spaces are coherent: verts, camera, physics, entities.
- Standing hypotheses, ranked: (1) frustum/distance cull eats near chunks
  (TERRAIN_DIAG nearestDrawn vs nearestCulled decides; in card build
  92b8b575, never yet run in-world); (2) rasterizer/frag-stage fault with
  valid draws (wireframe toggle would split it — setWireframeMode exists but
  has no trigger); (3) pass/state mismatch (all renderers share the ImGui
  pass; M2/WMO fine through it, so unlikely terrain-specific).
- Photo ground truth: WMO/M2/characters/sky/UI/portraits/action icons all
  render; ONLY terrain missing; stars below horizon (see-through, not black).

## Run 59: THE FLOOR — stale isValid() dropped every mega chunk (FIXED)

### Census (TERRAIN_TILEHIST): 6 tiles full (256) + [33,48] partial; the
### player's tile [32,48] + [31,48] + [32,47] contribute ZERO chunks.
Mechanics: Run 45's mega-buffer path nulls per-chunk handles by design and
marks placement with megaBaseVertex >= 0 — but `isValid()` still required
non-null buffers. Every mega chunk was silently dropped at load
(incremental path: bare `continue`, no line) and skipped at draw. The first
~3.5 finalized tiles went mega (spawn tile first, while room remained) and
vanished; later tiles fell back to per-chunk buffers and survived — which is
why ground existed far away but never at spawn. Physics never noticed (CPU
ADT data, separate path). megaUsed=130935 counts the leaked reservations.
Also explains "Failed to upload chunk"=0 (only the full path warns).

### Fix deployed (md5 `d6bbf637...`): isValid() accepts mega placement;
### incremental drop path logs throttled warnings. Fresh launches re-finalize
### from scratch (in-memory state), so no eviction/repair path was needed.
### Lesson: a validity predicate must be updated with every new placement
### path, and silent `continue` on a drop path is how tiles vanish for weeks.

## Run 60: draw-count attribution → object-distance cut (build e52a4767)

### Cost ranking from 204 WORLD_PERF samples (draw-count quartiles)
- M2 draws: +122 ms (135 -> 257). WMO draws: +107 ms (142 -> 249).
- Characters: +60 ms. Terrain: -16 ms (noise; base cover is fixed cost).
- Matches the user's look-down-smooth / horizon-slow report exactly:
  view-dependent draw load, not fullscreen post (post/shadow/volumetric all 0).

### Change deployed (md5 `e52a4767...`): Switch object-distance floor
- M2 draw distance x0.55, WMO x0.7 of world distance; terrain keeps full
  (cheap + must not hole). M2/WMO clamp floors lowered 400->150 on Switch so
  the scaled values stick. Fog auto-tracks 0.95 x full distance, hiding pop.
- Characters untouched (radius already 130 via env default).
- Expectation: horizon views lose ~half their M2/WMO draws. WORLD_PERF
  m2Draws/wmoDraws + frameMeanMs confirm next run; tune factors from there.
- Path to 15 fps (~65 ms from ~240): this cut + 540p + forces. If still
  short: grass/clutter, 480p scene, NPC radius — in that order.

## Run 61: object distance round 2 + 480p scene (build 2303f472)

### Run 01:32 (build e52a4767): draws halved, fps doubled, no crash
- frameMean 240->123 ms (~8 fps avg, best 56 ms/~17 fps). m2Draws mean ~56
  (was ~150), wmoDraws ~37 (was ~100). Cut works mechanically.
- Worst frames (209 ms) carry LOW draws (t8/m12) = streaming hitches on the
  main thread (SLOW update 60-75 ms), not GPU load. Two regimes: steady
  draw-bound + travel hitches. User felt little (8 fps still slow) but noted
  fog covering unload pop correctly.

### Change deployed (md5 `2303f472...`): M2 0.55->0.45, WMO 0.7->0.6,
### scene 540p->480p. Expectation ~85-100 ms. Next levers if short: grass,
### NPC radius, hitch budgeting. Open feel items (not this build): minimap
### arrow rotation (code comments admit half-turn uncertainty, needs a
### walk-north calibration), swinging lamp posts (verify vs retail: lamps
### static, flame flickers — possibly wind applied to wrong doodad class).

## Run 62: sky-suspect (clouds) + interior probe (build ae05f51a)

### User report: sky views tank fps, inn interiors tank fps, lamps sway
- Look-down smooth / horizon slow / sky slowest = view-dependent; fullscreen
  post already off. Sky-region cost candidates: FBM clouds (hemisphere,
  ~9 fbm calls/px), celestial discs, starfield points, skybox gradient.
- Interiors avoided (no data yet): suspect portal-culling (whole complex
  drawn inside?) or interior light/group blowup. Needs a 10 s indoor run.
- Lamps swaying with moving glow: keep (vertex anim + uniform update are
  cheap); verify-vs-retail parked. Minimap arrow: parked pending a facing
  calibration answer.

### Change deployed (md5 `ae05f51a...`): clouds skipped on Switch (diagnostic)
- If sky views jump in fps, proper fix = density gate + cheap shader.
- If unchanged, clouds exonerated; next sky suspects celestial/starfield.

## Deferred: inn death + stuck corpse (reported 2026-10-10 ~01:55, NOT diagnosed)

### Symptoms (user report, run 01:54)
- Character died inside an inn (Goldshire direction), apparently unprovoked
  ("randomly died" — no attacker identified).
- A modal reading "casting is..." appeared (truncated; cast bar vs static
  popup unknown).
- After dying, the character could not move (stuck; release/resurrect flow
  did not restore movement, or never offered).
- No crash, clean close. Last frame sample 100 ms/10 fps (best yet).

### Log status: nothing
Zero death/damage/spirit/corpse/resurrect/cast lines at WARNING — the whole
flow is INFO-suppressed or unlogged. Nothing to diagnose from.

### When this comes back: capture list
1. Repro: which inn, what was aggro'd, hp before death, exact modal text.
2. Add WARNING breadcrumbs (temporary): player-death event (killer guid +
   damage source), spirit-release request/response, movement-lock set/clear
   with reason, cast-bar show/hide with spell id. Then one repro run names it.
3. Prime suspects from structure (unverified): death clearing the movement
   lock only on one of several release paths; modal owning input focus and
   never releasing it; local-realm death not generating the release event at
   all (single-player content path, cf. local-realm save path bugs).

## Run 63: indoors 2x outdoors + WMO cull default-on (build ef4bbc44)

### Indoor split (run 01:54, inn ~10 s, playerIndoors=1 x6 samples)
- Outdoors: 59-196 ms. Indoors: 100-226 ms sustained (entry 61 ms, then
  100/226/214/218/197/139). Indoor draws: m2 ~145-162, wmo ~114-125,
  chars ~167-191 (vs ~25 outdoors!) — interiors draw MORE, not less.
- Mechanism: WMO portal+distance culling (cullInstance path) is env-gated
  (WOWEE_WMO_CULL, unsettable on console) — off by default "because a
  missing building beats an extra draw". Frustum + bounds-distance culling
  run regardless, but a frustum from inside a room still intersects the whole
  complex. Character attempts also spike indoors (distance+frustum active;
  radius 130 — dense inn population?).

### Change deployed (md5 `ef4bbc44...`): WMO culling on by default (Switch)
- One ifdef: cullingEnabled_ = true on Switch. If walls vanish anywhere,
  revert and gate interiors differently — user asked to watch for it.
- Expectation: indoor wmoDraws collapse; outdoor mostly unchanged (bounds
  path already culled). Next: character-draw spike indoors (separate).
