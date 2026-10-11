# First-run audit — will it boot on a real Switch?

Date: 2026-10-04
Branch: `audit/first-run-review` (branched from `main` @ `d0dc715`; **no source files changed**)
Scope: static audit + verification against the actual built artifacts and the
vendored libnx/Mesa sources in `references/`. **No hardware was available, so
nothing here was observed running.** Every item is labelled:

| Label | Meaning |
|-------|---------|
| **[VERIFIED]** | Proven by reading the code plus its callee/library in this repo. Will happen. |
| **[STRUCTURAL]** | Logic is certainly wrong; the visible symptom is inferred. |
| **[UNVERIFIED]** | Depends on Horizon/firmware/driver behaviour that cannot be checked here. |

---

## Executive summary

The port is in better shape than "never run on hardware" suggests. The Vulkan
loader contract, the `VK_NN_vi_surface` bring-up, the swapchain field set, the
first-frame acquire/submit/present ordering, the semaphore re-arm after rebuild,
HID init order, and the 48 kHz/2ch/Int16 audout parameters are all **correct**.
There is no PS4 or SDL3 code reachable on the Switch path. The client does not
need TLS, and the realm list arrives over the auth connection, so there is no
config file to hand-create before logging in.

But there are **six defects that will stop a first run**, and they are not in the
renderer — they are in audio, config paths, networking, and diagnostics:

| # | Severity | Area | Effect on first run |
|---|----------|------|---------------------|
| 1 | **BLOCKER** | Audio | Exactly one 21 ms grain of sound, then permanent silence. |
| 2 | **BLOCKER** | Config root | Every setting the user touches is silently lost; no log line. |
| 3 | **BLOCKER** | Local realm | Saves write to `/data/wow_ps/...`, which does not exist on Horizon → the *only supported* mode cannot save. |
| 4 | **BLOCKER** | Diagnostics | `showStartupError()` never shows its text — every failure is a bare error code. |
| 5 | **HIGH** | Sockets | `sin_len` unset on the auth/world connect + a single `fcntl` for non-blocking. |
| 6 | **HIGH** | Heap | `__nx_heap_size` asks for 1.5 GiB on a 2 GB console. |

Findings 1–4 are each independently sufficient to make the first run feel
broken, and **none of them produce a visible error** — which is the real
theme. This port fails *silently* by construction: `stdout` is not surfaced by a
homebrew process (`system_switch.cpp:75-77`), the log level is pinned to
`WARNING` with no way to change it on device, `installCrashReporter()` installs
nothing, and `showStartupError()` throws away the message. **Fix the
diagnostics before the hardware run, or the first real bug will be
undiagnosable.**

---

## BLOCKER 1 — Audio dies after ~21 ms (double-wait on `audout`) **[VERIFIED]**

`wowee/src/platform/switch/audio_backend_switch.cpp:39-48, 156-180`

```cpp
bool waitForGrainRelease() {
    if (!g_port.inFlight) return true;
    ...
    const Result rc = audoutWaitPlayFinish(&released, &releasedCount, 1000000000ULL);
    g_port.inFlight = false;
    return R_SUCCEEDED(rc) || releasedCount > 0;
}
...
    if (R_FAILED(audoutPlayBuffer(&buf, &released))) { ... }
    g_port.inFlight = true;      // :178
```

The premise — stated in the comment at `:36-38` — is that `audoutPlayBuffer` is a
plain append that leaves pacing to the caller. It is not. `references/libnx/nx/source/services/audout.c:160-171`:

```c
Result audoutPlayBuffer(AudioOutBuffer *source, AudioOutBuffer **released) {
    rc = audoutAppendAudioOutBuffer(source);
    if (R_SUCCEEDED(rc))
        rc = audoutWaitPlayFinish(released, &released_count, UINT64_MAX);  // blocks + harvests
    return rc;
}
```

`audoutPlayBuffer` **already blocks until the grain finishes and already
harvests it** from the released list (`audoutWaitPlayFinish` at `audout.c:141-158`
does `eventClear` → poll → `eventWait` → poll).

Trace:
- Period 1: `inFlight == false` → no wait → `audoutPlayBuffer` blocks ~21 ms,
  harvests the release → returns → `inFlight = true`.
- Period 2: `inFlight == true` → `waitForGrainRelease()` → `eventClear` →
  `audoutGetReleasedAudioOutBuffer` returns **0** (already harvested) →
  `eventWait(1 s)` → `RC_TIMEDOUT` → returns `false` → `devWrite` returns
  `MA_ERROR` after a **1-second stall**.

miniaudio then kills the device permanently — `extern/miniaudio.h:20833-20835`:

```c
result = ...onDeviceWrite(...);
if (result != MA_SUCCESS) { exitLoop = MA_TRUE; break; }
```

The result is discarded by the worker thread, which proceeds to `onDeviceStop`
→ `audoutStopAudioOut()`, state `stopped`. `notificationCallback` is never
configured, so **nothing else is logged**.

**Symptom:** one 1024-frame grain of audio, then silence forever. One
`LOG_ERROR("audout did not release the previous grain")` in `wowps.log`. No
crash, no visible error.

**Fix:** delete the pre-wait gate entirely — `audoutPlayBuffer` already provides
the ordering guarantee. For real double-buffering use
`audoutAppendAudioOutBuffer` + an explicit `audoutWaitPlayFinish` with 2 grains
in flight.

---

## BLOCKER 2 — `getConfigRoot()` resolves to a directory nothing creates **[VERIFIED]**

`wowee/src/core/config_paths.cpp:153-176`

```cpp
std::string getConfigRoot() {
    if (const char* root = std::getenv("WOWEE_CONFIG_ROOT"); root && *root) { ... }  // never set
    const std::string exeDir = getExecutableDir();       // == appRoot() on Switch
    if (fs::exists(exeDir / "portable.txt") || fs::is_directory(exeDir / "config"))
        return (exeDir / "config").string();
    return perUserConfigDir();                            // $HOME/.wowps
}
```

Chain:
1. `applyEnvironment()` (`system_switch.cpp:179-197`) sets `WOW_DATA_PATH`,
   `HOME`, `TMPDIR` — **never `WOWEE_CONFIG_ROOT`**.
2. `getExecutableDir()` on Switch is `appRoot()` (`config_paths.cpp:124-125`) =
   `sdmc:/switch/wowee/data`.
3. The packaged `wowee-data/` has `assets/`, `Data/` — **no `config/`, no
   `portable.txt`** → portable branch skipped. (This is the "first candidate
   exists but is wrong" pattern: `sdmc:/switch/wowee/data` is *guaranteed* to
   exist and is the wrong place to look for config.)
4. `createDirectories()` (`system_switch.cpp:119-128`) creates
   `sdmc:/wowps/wowps/{logs,cache,saves,config,tmp}` — but `getConfigRoot()`
   never returns `.../config`. So **`saves/` and `cache/` are dead directories**
   while `.../.wowps` is used and never created.

Only three call sites self-heal with `create_directories`
(`ui/auth_screen.cpp:1391,1399,1563`; `addons/addon_manager.cpp:641`).
Everything else fails silently:

| File | Site | Failure |
|------|------|---------|
| `settings.cfg` | `auth_screen.cpp:1853` | `if (!out.is_open()) return;` — **no log line at all** |
| `addons.cfg` | `addon_manager.cpp:623-627` | `LOG_WARNING` only |
| `cvars.cfg` | `addons/lua_system_api.cpp:578` | silent |
| `interface_state.cfg` | `addons/lua_system_api.cpp:3146` | silent |
| `bindings.cfg` | `addons/keybinding_manager.cpp:377` | silent |
| `imgui.ini` | `ui/ui_manager.cpp:112` | ImGui silently skips the write |
| `lua_errors.txt`, `missing_api.txt` | `addons/lua_engine.cpp:9581-9615` | **the two files a bug report is read from** |
| `cache/wmo_floor_*.bin` | `wmo_renderer.cpp:1711,1756` | silent |

**Symptom:** before a successful first login, every graphics/audio setting the
user touches is lost with no diagnostic.

**Fix (one line):** `setenv("WOWEE_CONFIG_ROOT", writableRoot(), 0)` in
`applyEnvironment()`, or return `writableRoot()` directly under `WOWEE_SWITCH`.

---

## BLOCKER 3 — Local-realm saves target a PS4 path that does not exist **[VERIFIED]**

`wowee/src/core/application_local_realm.cpp:108-114`

```cpp
std::string localSaveDirectory() {
#ifdef WOWEE_SWITCH
    return "/data/wow_ps/saves/local_realm";
#else
    return getConfigRoot() + "/saves/local_realm";
#endif
}
```

`/data` is the PS4 read-only `/app0` sandbox. The Switch writable root is
`sdmc:/wowps/wowps` (`system_switch.cpp:52`). `LocalRealm::prepare()` calls
`ensureDirectory(path)` → `std::filesystem::create_directories("/data/wow_ps/...")`
(`game/local_realm.cpp:1213-1218, 3807`), which fails → `fail("Cannot create local
realm save directory")`.

This matters because **local/private realms are the only supported mode** —
Blizzard's Warden cannot execute native modules on Horizon (no anonymous RWX
mappings), per `docs/BUILD_SWITCH.md:191-227`. The documented target is the one
mode that cannot save.

Same class of bug at `application_local_realm.cpp:61`
(`/data/wow_ps/realm/world.json`) and `game/local_realm.cpp:3810`
(`/data/wow_ps/...`, `/app0/...`, plus a bare relative
`"assets/local_realm/world.json"` that cannot resolve because
`enterResourceRoot()` deliberately never sets a CWD —
`config_paths.cpp:37-38`).

And user-facing error text at `application_local_realm.cpp:192` and `:484` tells
the user on-screen to *"Copy your WotLK 3.3.5a MPQs to `/data/wow_ps/Data`"* —
wrong path, guaranteed to mislead.

The same file proves the author knew this was the bug class — `:118-124`:

> *"…rather than through **a second hardcoded literal that would silently disagree
> with it**"*

…and then line 127 does it correctly (`writableRoot() + "/create_test_characters"`)
while lines 61 and 110 are exactly that second hardcoded literal.

**Fix:** route all three through `platform::switchport::writableRoot()`.

---

## BLOCKER 4 — `showStartupError()` shows no text **[VERIFIED]**

`wowee/src/platform/switch/system_switch.cpp:354-361`

```cpp
void showStartupError(const char* message) {
    std::fprintf(stderr, "[wowee/switch] FATAL: %s\n", message ? message : "(null)");
    reportBootStage("fatal: startup error");
    fatalThrow(MAKERESULT(Module_Libnx, LibnxError_ShouldNotHappen));
}
```

`fatalThrow` renders only `LibnxError_ShouldNotHappen` — literally *"Threw fatal
error type 2"* (`references/libnx/nx/source/services/fatal.c:56-61`), which is
the symptom `docs/BUILD_SWITCH.md:154-156` already documents. `stderr` is not
surfaced.

This is the sink for the two best first-run messages in the tree:

- `main.cpp:190-195` — *"bundled resources missing; searched … copy
  build-switch/wowee-data there as data/, next to the .nro"*
- `application.cpp:1296-1304` — *"Your game data was not found. Expected the WotLK
  client Data directory at: `sdmc:/wowps/Data` … or create
  `sdmc:/wowps/wowps/config/paths.cfg`"*

**A first-run user with data in the wrong place has no way to learn where to put
it.** The header claim at `switch_platform.hpp:58` ("Show a bounded system error
dialog") is not what libnx does.

**Fix:** `errorApplicationShowDialog` / `appletCreateErrorApplication`, or render
an ImGui frame with the text before `fatalThrow`.

---

## HIGH — sockets: `sin_len` unset, and a single `fcntl` for non-blocking **[VERIFIED]**

`wowee/include/network/net_platform.hpp:302-305`

```cpp
memset(&addr, 0, sizeof(addr));
addr.sin_family = AF_INET;
addr.sin_addr = ...;
addr.sin_port = htons(port);
// no sin_len
```

then `::connect(s, ..., sizeof(address))` at `:220`.

The codebase **contradicts itself**, which is the tell — `sin_len` is set in three
other places and not here:

- `src/auth/auth_packets.cpp:22-24` (`#ifdef WOWEE_SWITCH`)
- `src/game/local_realm.cpp:1150-1156` (+ `openSocket()` calls it at `:3228`)
- `include/game/lan_discovery.hpp:26-31`

Horizon's netstack is FreeBSD-9-derived and BSD `connect`/`bind` validate
`sa_len`. If required, the *only* path missing it is the auth and world TCP
connect — so login and world entry fail with `EINVAL` while the LAN browser and
local-realm UDP work fine. **[UNVERIFIED]** on hardware, but the asymmetry is
almost certainly unintentional.

Second, `include/platform/switch/socket_control.hpp:8-13` uses bare `fcntl`
only:

```cpp
inline bool setSocketNonBlocking(int socket) {
    const int flags = ::fcntl(socket, F_GETFL, 0);
    return flags != -1 && ::fcntl(socket, F_SETFL, flags | O_NONBLOCK) != -1;
}
```

and `net_platform.hpp:282-288` treats failure as fatal to the connect. The repo's
own changelog records this exact call failing on the sibling console port —
`CHANGELOG.md:21`:

> *"use the PlayStation `SO_NBIO` socket option … This replaces the `fcntl` mode
> switch that returned **`EACCES` on a reported console and stopped login before
> contacting the auth server**."*

`docs/CONNECTING.md:25-29` documents the resulting user-visible string as a known
symptom. There is **no `SO_NBIO` / `ioctl(FIONBIO)` / `SO_RCVTIMEO` fallback
anywhere** on the Switch path. Two failure modes: `fcntl` returns −1 → every
connect hard-fails before the handshake; or `fcntl` returns 0 but Horizon ignores
it → `connect()` **blocks on the main thread** for the OS TCP timeout and `recv()`
blocks forever → the app freezes.

Tests don't cover it: `tools/tests/network_transport_test.cpp:118-120` exercises
`setSocketNonBlocking` against a *host* loopback socket, and
`ps4_socket_control_test.cpp` covers only the PS4 adapter.

**Fix:** set `sin_len` at `:303`; give `setSocketNonBlocking` a
`setsockopt`/`ioctl` fallback chain and log which rung succeeded; mirror the PS4
adapter's test.

---

## HIGH — `__nx_heap_size` = 1.5 GiB on a 2 GB console **[UNVERIFIED, but unsafe]**

`wowee/switch/third_party/nxvk/nvk_compat.c:154`

```c
size_t __nx_heap_size = 1536u * 1024u * 1024u;
```

devkitPro's own Switch template uses `0x10000000`–`0x14000000` (256–320 MiB).
Add the ~38.8 MB appended romfs, the 39.6 MB romfs mapping, and Atmosphère's own
footprint, and a retail/erratum 2 GB console has no chance of `svcSetHeapSize`
succeeding. This is the single most likely "compiles fine, dies at launch" item.
Nothing verifies the grant succeeded or degrades the value.

Same file `:74` compounds it:

```c
case _SC_PHYS_PAGES:  return (3ll * 1024 * 1024 * 1024) / 4096;
```

Mesa/NVK sizes host-visible and WIP heaps from this, so it is told the machine has
3 GiB of RAM when it has 2 — a second over-commit source.

---

## HIGH — build: `${CMAKE_PYTHON_EXECUTABLE}` is never set **[VERIFIED]**

`wowee/CMakeLists.txt:1062-1064`

```cmake
        COMMAND ${CMAKE_PYTHON_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/tools/switch/patch_nro_romfs.py
```

`CMAKE_PYTHON_EXECUTABLE` is set by `FindPythonInterp`, not `FindPython`. The
project only does `find_package(Python3 ...)` (`:42`), and the other three Python
invocations correctly use `${Python3_EXECUTABLE}`. The generated
`build-switch/build.ninja:4265` confirms it — the script path appears with no
interpreter in front of it.

It only "works" on this machine because WSL drvfs reports every file as `0777`.
The file is committed mode `100644`. On a native Linux clone the POST_BUILD step
is `Permission denied` → ninja fails → `build_switch_nro.sh` (which uses
`set -euo pipefail`) aborts at line 101 → **you never get an NRO at all**.

**Fix:** `${CMAKE_PYTHON_EXECUTABLE}` → `${Python3_EXECUTABLE}`.

### Related build findings

- **All six switch scripts are committed non-executable** (`100644`), yet the
  documented flow execs them directly — `README.md:45-46`,
  `docs/BUILD_SWITCH.md:53`. The *first* documented command fails on a fresh
  clone. Needs `git update-index --chmod=+x` or `bash <script>` invocation.
- **Asset staging hangs off the link edge** (`CMakeLists.txt:1033-1036`,
  `add_custom_command(TARGET wowee PRE_LINK ...)`). There is no stamp target and
  no `BYPRODUCTS`, so ninja's dirty check only considers `.o` files. Edit a
  `.glsl`, rebuild → the link is up to date → `wowee-data/`, `wowee-romfs.bin`
  and `wowee.nro` all keep the **old** `.spv`. This silently defeats the stated
  purpose of the `rm -rf assets/shaders` line and of `verify_shaders.py`.
  Secondary: `:985` `file(GLOB ...)` has no `CONFIGURE_DEPENDS`, so a *newly
  added* `.spv` needs a manual re-configure.
- **The romfs story is self-contradictory across four files.** `README.md:52-53`
  and `BUILD_SWITCH.md:82-86` say assets are *not* in a romfs;
  `CMakeLists.txt:1042-1043` and `system_switch.cpp:230-240, 471-473` say they
  are, and `romfs:/` is an `appRoot()` candidate. The artifacts settle it —
  `wowee.elf` 47.0 MB, `wowee-romfs.bin` 39.6 MB, `wowee.nro` **78.4 MB** — the
  romfs *is* appended and patched. `BUILD_SWITCH.md:88-97` also omits `romfs:/`
  from the documented search order.
- **Bundled addons are staged where the client never looks.**
  `tools/switch/package.sh:47` writes `sdmc:/switch/wowee/addons`;
  `addons/addon_manager.cpp:167` reads `resolveRelativeAssetPath("addons")` →
  `sdmc:/switch/wowee/data/addons`. **Mismatch** — the one bundled addon
  (`WoweeAllBags`) is silently never scanned.
- **Two `package_staging` tests crash** (red release gate).
  `tools/tests/package_staging_test.py:9` and `package_staging_0178_test.py:8`
  parse a PS4-era `package.sh` containing embedded python heredocs; the current
  homebrew stager has none → `IndexError`. `run_release_checks.py:16` registers
  them, so `run_release_checks.py` exits 1, contradicting
  `docs/BUILD_VALIDATION.md:16` ("All 12 self-contained release suites passed" —
  there are 14 now).
- **No capability validation on the Switch swapchain path.**
  `rendering/vk_context.cpp:1313-1355` queries `SurfaceCapabilitiesKHR` then never
  uses them: no clamp of `imageExtent` to `min/max/currentExtent`, no
  `minImageCount >= caps.minImageCount`, no `presentMode ∈ supportedPresentModes`,
  no `imageUsage & ~supportedUsageFlags`. The values used *are* correct for this
  driver (verified below), so this is fragility, not a current failure.
- **NACP version is a literal** (`CMakeLists.txt:1040`, `"2.12.0"`) while
  `cmake/GitVersion.cmake` derives the in-binary version from `BUILD_VERSION`.
- `assets/` staging is a hardcoded 5-entry allowlist (`CMakeLists.txt:1022`) vs
  desktop's whole-directory copy — any new asset ships on desktop, silently
  dropped on Switch. Three of the five (`krayonload.png`, `krayonsignin.png`,
  `orgrimmar-entrance.png`, ~11.2 MB) are referenced nowhere in the tree.
- `ps4DebugSolidDraw()` is compiled on Switch (`rendering/vk_context.cpp:3561-3562`)
  and loads `switch_debug_solid.{vert,frag}.spv` — files that **do not exist**,
  and whose PS4-named siblings are explicitly excluded from staging by
  `CMakeLists.txt:986`. No `#if defined(WOWEE_PS4)` guard (unlike the sibling
  `ps4DebugComputeDispatch` at `:3357`). Latent, flag defaults off.

---

## HIGH — no `appletHook`, and the exit request is ignored **[VERIFIED]**

`grep appletHook wowee/` → **0 matches.**

- **Suspend/resume/dock is entirely unhandled.** The path that does this is
  `#ifdef __ANDROID__` (`core/application.cpp:1497-1510`). The sleep button, Home
  overlay and dock/undock all change the VI layer behind the app; nothing
  re-reads dimensions or rebuilds the surface. `appletProcessMessage` calls
  `appletCallHook` for every message, but with no cookie registered it is a
  no-op — so focus state is never even refreshed.
- **The applet exit request is detected, logged, and then ignored.**
  `system_switch.cpp:522-535` sets `g_exitRequested`, which has **no getter and no
  reader anywhere in the tree**. The main loop is
  `while (running && !window->shouldClose())` (`application.cpp:1395`), and on
  Switch `shouldCloseFlag` is only set by `SDL_QUIT` — which the SDL shim never
  pushes. After **Close Software** the game keeps presenting forever and becomes
  unkillable except by a forced close.
- Combined with `rendering/vk_context.cpp:3870-3874`, where any present failure
  sets `deviceLost_ = true` permanently with no recreation path
  (`renderer.cpp:1286` returns immediately forever), this is the most likely
  "worked once, then black screen forever".

**Fix:** `appletHookInitialize()` + `appletHook()` before the first
`appletMainLoop()`, with suspend/resume/operation-mode handling including
`audoutFlushAudioOutBuffers` and swapchain invalidation; expose
`g_exitRequested` to the loop or synthesise `SDL_QUIT`.

---

## HIGH — the crash reporter is a no-op in both branches **[VERIFIED]**

`main.cpp:158-164` + `system_switch.cpp:342-347`

```cpp
bool installCrashReporter() {
    // "Horizon has no per-thread signal-stack service ..."
    return g_bootFd >= 0;      // only a query — installs nothing
}
```

- **Normal path** (`g_bootFd >= 0`): `main()` **skips installing SIGSEGV /
  SIGABRT / SIGFPE / SIGILL / SIGBUS entirely**. Only SIGTERM/SIGINT are hooked
  (`:234-235`). A segfault writes **no** log line; the only evidence is the last
  `[boot]` breadcrumb.
- **Fallback path** (`g_bootFd < 0`): handlers *are* installed, but
  `reportCrashSignal` bails immediately — `system_switch.cpp:325`
  `if (g_bootFd < 0) return;`.

Also note `main.cpp:155-157` claims *"Through the kernel's own `sigaction` ABI, on
an alternate stack"* — the opposite branch is taken, because
`installCrashReporter()` runs at `:158` **before** `initSystem()` at `:176`, so
`g_bootFd == -1`.

**Fix:** install the handlers unconditionally (there is no libnx alternative —
`registerCrashReportingThread` at `system_switch.cpp:349-352` is an empty stub),
and give `reportCrashSignal` a descriptor it opens itself.

---

## HIGH — the loader's failure mode is a silent infinite hang **[VERIFIED]**

`src/platform/switch/vk_nxvk_loader.cpp:44-52`

```cpp
std::fprintf(stderr, "[wowee/switch] nxvk: driver has no entry point '%s'\n", name);
while (true) { svcSleepThread(1000000000LL); }
```

This is the *only* failure mode of the loader contract, and it produces a black
screen with the title frozen on the loader screen and **zero diagnostics** —
`stderr` is not surfaced, and this file deliberately avoids the platform layer,
so unlike `beginFrame`/`endFrame` it writes no boot breadcrumbs.

The trigger is real, not theoretical: any instance-level trampoline reached with
`g_instance == VK_NULL_HANDLE` resolves via `vk_icdGetInstanceProcAddr(NULL, name)`
(`:55`), Mesa returns NULL for anything non-global, and `g_instance` is only set
by **our own** `vkCreateInstance` wrapper (`:107`). `vkQueueSubmit`,
`vkEnumeratePhysicalDevices`, `vkGetPhysicalDeviceSurfaceCapabilitiesKHR` all
land here.

Related: Vulkan bring-up writes **no boot.log breadcrumbs** at all, so a hang
inside `vkCreateSwapchainKHR` leaves `boot.log` ending at
`"application: main loop"`.

**Fix:** write to the boot log (or `svcOutputDebugString`, or a file under
`sdmc:`), and/or return a benign error instead of sleeping.

---

## MEDIUM — assorted

### Thread stacks: 128 KiB everywhere, and the PS4 port already overflowed on this **[STRUCTURAL]**

`src/platform/switch/threads_switch.cpp:1-9` says:

> *"The PS4 port needed a real pthread_create interposer because the console
> defaulted to a small stack and miniaudio's device thread (MP3 decode) overflowed
> it. On Switch the practical fix lives where the stack is chosen … the client
> asks the same for its own long-lived worker threads through
> `defaultThreadStackBytes()` so callers can log the value at startup."*

`defaultThreadStackBytes()` **is never called** — only declared and defined. And
`grep pthread_attr_setstacksize` over `src` + `include` → no hits. Only
`audio/audio_engine.cpp:224` sets a stack (2 MiB, device thread only). libnx's
newlib defaults every other thread to **128 KiB**
(`references/libnx/nx/source/runtime/newlib.c:164-190`).

Unfixed: miniaudio's **resource-manager job thread**
(`ma_resource_manager_config_init` leaves `jobThreadStackSize = 0`,
`miniaudio.h:69965`; spawned at `:70101`) — which is the thread that actually runs
`dr_mp3` decode + resampling, i.e. exactly what overflowed on PS4; plus
`ThreadPool::frameWorkers()` (7 threads), `extract_switch.cpp:233` MPQ worker,
`world_socket.cpp:384`, `world_loader.cpp:1537`, `snapshot_writer.hpp:31`.

No `__nx_thread` / priority / QoS / affinity anywhere — so no *inversion*, but
also render workers and the audio thread share cores and QoS.

No missing `threadJoin` found; shutdown joining looks correct.

### 512 MiB memory probe, up to 10×/s, from a worker loop **[STRUCTURAL]**

`include/platform/switch/cpu_memory.hpp:62-70`

```cpp
const std::size_t ladder[] = { 512u*1024*1024u, 256u*1024*1024u, 128u*1024*1024u, ... };
```

Every pressure consumer re-runs the whole ladder — `memory_monitor.cpp:132,167,181`;
**`terrain_manager.cpp:1913` inside the tile-preparation worker loop** next to an
unthrottled `queueCV.wait_for(100ms)`; `entity_spawner.cpp:122` at 10 Hz (which
calls it *again* internally → 2 probes per call); plus `asset_manager.cpp`,
`renderer.cpp`, `world_loader.cpp`, `addon_manager.cpp`. Against
`__nx_heap_size = 1536 MiB` and `kCpuMemoryBudgetLimit = 448 MiB`
(`cpu_budget.hpp:39`), this is a 512 MiB mmap/first-touch/munmap cycle racing
`allocateCpuGeometry()` for the same arena — and **the probe perturbs the quantity
it is measuring**. The throttled-sample pattern already exists in the tree
(`asset_manager.cpp:210-264`); `MemoryMonitor` just doesn't use it.

Related: `kCpuGeometryLimit = 128 MiB` (`include/platform/cpu_geometry.hpp:13`) is
bookkeeping, not a reservation — `cpu_geometry.cpp:17-35` is a plain
`aligned_alloc` from the same heap, and its header comment describes PS4 Onion
memory that the Switch path does not implement.

### No network-availability check; nothing retries; default realm is `localhost` **[VERIFIED]**

`src/ui/auth_screen.cpp:239-244`

```cpp
if (hostname_.empty()) hostname_.setText("localhost");
```

`grep nifmInitialize|nwmInitialize|nwmGetConnectionStatus|NetworkConnectionStatus|wifi`
over `src` + `include` → **no hits**. Nothing checks whether the Switch has an IP
or is on Wi-Fi. At cold boot the APIPA/link-local window before DHCP completes is
real, and `getaddrinfo` returns failure with no retry. The only reachable paths
are `auth_screen.cpp:349-353` — *"Connection timed out - server did not respond"*
(a failure, not a wait) — or the user re-pressing Connect. The `localhost` default
guarantees the very first press fails.

### WoW integrity ("CRC") hash is computed from relative paths that cannot resolve **[VERIFIED]**

`src/auth/auth_handler.cpp:313-331` builds candidates `"Data/expansions/wotlk/misc"`,
`"Data/misc"`, … and `integrity.cpp:11-13,71-76` reads them with `std::ifstream`.
On Switch there is no working directory — `enterResourceRoot()` explicitly
"NEVER changes the working directory" (`config_paths.cpp:37-38`) and every other
asset read was rerouted through `resolveRelativeAssetPath()`. This is the **one
auth-packet path not migrated**. `crcHashPtr` stays null and the only log is a
`LOG_WARNING` suggesting an env var (`WOWEE_INTEGRITY_DIR`) a console user cannot
set. Servers that enforce it will reject the login.

### `s_applicationKeyboardOpen` can disable all input with no recovery **[VERIFIED]**

`input_switch.cpp:800, 992-995`. Process-global, no watchdog — only a 200 ms grace
on close. Writers are `ui/character_create_screen.cpp:120,712,816`. Any path that
leaves character creation while `nameKeyboard_.open` is true without calling
`reset()` leaves **no controller input at all** for the rest of the session (every
binding skipped, ImGui gamepad nav dead). No message, no log.

### Touch moves the cursor but can never click **[VERIFIED]**

`input_switch.cpp:547-562`. `s_touchWasDown` is tracked for exactly one purpose
(forcing a zero-relative motion event on the first frame of a touch) and never
produces an `SDL_MOUSEBUTTONDOWN`. There is no tap-to-click anywhere in the tree;
`hidTouchAttribute_*` is never consulted. First-run UX: on the login screen you
must navigate with the right stick and press Cross — touching a button does
nothing. Multi-touch is reduced to `touches[0]`.

### `HidNpadStyleSet_NpadFullCtrl` excludes single Joy-Con **[VERIFIED against libnx]**

`input_switch.cpp:738`. `NpadFullCtrl` = `NpadFullKey | NpadHandheld | NpadJoyDual`
(`references/libnx/nx/include/switch/services/hid.h:245-246`) — a single attached
Joy-Con (`NpadJoyLeft`/`NpadJoyRight`) is not in the declared set, so it is not
read. `NpadStandard` would cover it. Also only `No1` + `Handheld` are declared, so
a 2nd/3rd controller is never read.

### `initInput()` can leave HID initialised but `s_initialised == false` **[STRUCTURAL]**

`input_switch.cpp:729-746`. If `hidSetSupportedNpadIdType`/`StyleSet` fails, the
function returns false **without calling `hidExit()`** — a second `initInput()`
would re-`hidInitialize()` and leak the `g_hidIAppletResource` session. Currently
unreachable (one call site, `window.cpp:79`) but fragile. Note
`hidInitializeNpad()`/`hidInitializeTouchScreen()` **diagAbort** on failure
(`references/libnx/.../hid.c:232-235, 305-308`) — an uncatchable hard abort, not a
`return false`.

### `fsdevMountSdmc()` failure is non-fatal and leaves zero diagnostics **[VERIFIED]**

`system_switch.cpp:206-226`. The SD card is the only writable store. If the mount
or the boot-log `open()` fails, `klog` writes to `stdout` (invisible),
`g_bootFd` stays −1 so `appendBootLine` is a no-op and `reportCrashSignal` returns
immediately, and `initSystem()` still returns `true` (`:277`) — so the client
proceeds into an asset failure whose only user-visible artifact is BLOCKER 4's
bare error code.

### Log level is not user-settable on device **[VERIFIED]**

`include/core/logger.hpp:74-79` — `NDEBUG`/`WOWEE_RELEASE_LOGGING` ⇒ default
`WARNING`. `main.cpp:98` reads `WOWEE_LOG_LEVEL`, which no console user can set.
So on hardware **all `LOG_INFO` is permanently suppressed**, including
`asset_manager.cpp:172-174` (cache budget), `mpq_asset_source.cpp:80-82` (archives
opened), and `expansion_profile.cpp:166` (active profile). The appRoot candidates
survive via `klog`→boot.log, which is the right call.

### `LoadingScreen` cannot service `swapchainDirty` on Switch **[VERIFIED]**

`rendering/loading_screen.cpp:362-366` guards on `sdlWindow`, which is `nullptr` on
Switch (`window.cpp:85` passes `nullptr` to `vkContext->initialize`). If the first
present answers `VK_SUBOPTIMAL_KHR`/`OUT_OF_DATE` while the loading screen owns
the frame, the swapchain is never rebuilt.

### Repeated `VK_SUBOPTIMAL_KHR` would rebuild the swapchain every frame **[UNVERIFIED]**

`vk_context.cpp:3880-3884` + `:1414`. On desktop `presentsOffNativeTransform_`
suppresses a permanent-suboptimal rebuild loop (see the comment at `:1246-1262`).
The Switch branch hardcodes `false` and takes `preTransform = caps.currentTransform`.
If NVK ever answers SUBOPTIMAL for that transform, every frame runs
`recreateSwapchain` — waitIdle, destroy/recreate swapchain, render passes,
framebuffers, all pipelines.

### `extractAtStartup()` is dead code **[VERIFIED]**

`extract_switch.cpp:185-198` defines it; no caller exists anywhere in
`src`/`include`/`tools`. `application.cpp:360` calls only `prepareAssetMetadata()`,
which just logs `plan.hasArchives`. So the first-launch MPQ extraction the whole
file exists for never runs. It works today only because the packaged
`Data/expansions/wotlk/` has no `manifest.json` — add one and
`application.cpp:386-397` flips `assetPath` to the read-only bundled dir, and
`AssetManager::initialize` then fails → BLOCKER 4.

### Relative-path writes on a platform with no CWD **[VERIFIED]**

| site | path | gated? |
|------|------|--------|
| `network/world_socket.cpp:287` | `ofstream("charcreate_payload.log")` | **no** — every character creation |
| `ui/game_screen_hud.cpp:1761-1764,1779` | `$HOME/.wowps/screenshots/…` | **no `create_directories`** — screenshot silently fails |
| `rendering/camera_controller.cpp:1673` | `/tmp/wowee_floor.log` | `WOWEE_FLOOR_DEBUG`; `/tmp` absent on Horizon |
| `game/warden_handler.cpp:429` | `create_directories` — the **throwing** overload, unique in the tree | on module load |

### Smaller items

- `rendering/vk_context.cpp:2789-2791` — `releaseSurface()` skips
  `vkDestroySurfaceKHR` on Switch, but a `VK_NN_vi_surface` *is* a real
  `VkSurfaceKHR`. Dead today (Android-only caller), a trap if enabled: it nulls the
  handle, leaking the surface, and `restoreSurface()` would then create a second
  surface over the same NWindow.
- `rendering/vk_context.cpp:662` forces `blockCompressionSupported_ = false` while
  `:801` enables `textureCompressionBC` — dead feature enabling.
- `rendering/vk_context.cpp:622-639` picks the first graphics family and assumes
  present support without calling `vkGetPhysicalDeviceSurfaceSupportKHR`. True for
  NVK (single family), unverified in general.
- `vk_context.cpp:456` hardcodes `instanceApiVersion_` and never calls
  `vkEnumerateInstanceVersion`; `VMA_VULKAN_VERSION 1000000` and ImGui's
  `ApiVersion = VK_API_VERSION_1_0` are consistent with requesting 1.1. A
  capability limitation, not a bring-up risk.
- `audio_backend_switch.hpp:14` doc comment says "float"; the implementation is
  s16 (`:23`). The device is opened s16 while miniaudio's engine asks for
  `ma_format_f32`, so a per-period f32→s16 converter runs for nothing.
- `audio_backend_switch.cpp:99-106` hard-compares `audoutGetChannelCount()` to 2.
  **The value is correct today** (libnx requests `0x00020000`, the service
  normalises `≤2 → 2`), and audio-init failure is handled *correctly* (silent,
  non-fatal, game keeps running — `audio_coordinator.cpp:33-37`,
  `application.cpp:295-296`). But any libnx bump turns this into a permanent
  silent no-audio. Prefer accepting what audout returns and converting.
- `audio_backend_switch.cpp:154` calls `reportBootStage` from the **audio thread**,
  which `switch_platform.hpp:42` documents as main-thread-only. Benign today.
- `system_switch.cpp:419-441` — `findAssetsBesideLaunchDirs()` scans only **64**
  entries. It is the *recovery* path, and `BUILD_SWITCH.md:141-142` already warns
  that emulator SD views lag file copies. Wrong thing to bound.
- `system_switch.cpp:504-520` — `resolveIPv4()` is implemented and documented
  ("may be called from any thread") but has **zero callers**.
- `system_switch.cpp:312` writes an **empty timestamp** in the `reportBootStage`
  fallback branch, so pre-`initSystem` breadcrumbs are undated. `char line[1024]`
  (`:83`) silently truncates long ones, e.g. `application.cpp:190-193`.
- `main.cpp:147-149` guards all of `main`, and `system_switch.cpp:282-288` calls
  `socketExit(); fsdevUnmountAll();` — but `Logger`'s `static std::ofstream` closes
  at *static-destruction* time, i.e. after the SD card is unmounted. Line-level
  flushing (`logger.cpp:238-244`) mostly hides this.
- `switch/compat/src/bn.cpp:25` logs with the prefix `[ps4-crypto-shim]` on Switch
  builds. The shim itself is fine — spot-checked `BN_mod` (`:711-713` → `BN_div`)
  and `BN_mod_exp` (`:743-758`); SRP needs only 2 modpows per login.
- `docs/BUILD_AND_RELEASE_NOTES.md:49,73,30,80` and `wowee/README.md:172` document
  a PS4-only build (`tools/ps4/build_ps4_pkg.sh`, `cmake/ps4.toolchain.cmake`,
  `ps4/third_party/ps4_vulkan/`) that **does not exist in this tree**. Stale.
- `docs/BUILD_SWITCH.md:79` documents `sdmc:/wowps/assets/local_realm`;
  `CMakeLists.txt:1001-1003` stages it to `<appRoot>/assets/local_realm`. Wrong.
- `docs/BUILD_SWITCH.md:244` points the loader-regeneration step at
  `references/nxvk/include/vulkan` — `references/` is gitignored, so that path
  does not exist on a clean clone.
- `config_paths.hpp:53-54` header comment says the Switch anchor is `/app0`; the
  implementation uses `appRoot()`. Stale, and misleading given BLOCKER 3.
- `fetch-nxvk.sh` needs podman/docker **and** an interactive `sudo make install`
  (`:61`), and pins `--branch switch` (`:33`) — yet the build that actually
  succeeded used the *other* route (`cmake/switch/nxvk.cmake:43-48`, the jhuz0
  prebuilt drop-in: `build.ninja:4262`
  `-Wl,--whole-archive /opt/devkitpro/portlibs/switch/lib/libvulkan.a`), which
  the docs never present as *the* driver source. That branch also has **no**
  `--whole-archive`/`-u,vk_icdGetInstanceProcAddr` (only the prebuilt branch does),
  so `--gc-sections` can drop driver objects reachable only via registration.
- `nxvk.cmake:20-21` adds only `${WOWEE_NXVK_PREFIX}/include`, but the client needs
  `#include <vulkan/vulkan.h>` **and** `VK_USE_PLATFORM_VI_NN`. If the archive
  installs under `include/vk_video/` (jhuz0's actual layout) the first compile of
  `vk_context.cpp` fails. Nothing pins or checks the header root. **[UNVERIFIED]**
  — this is the configuration that actually built.
- `nxvk.cmake:32` clobbers `PKG_CONFIG_PATH` for the whole configure, discarding
  whatever the caller exported.
- `switchpkg` hardcodes `bash` (`CMakeLists.txt:1069`, no check that it exists) and
  a literal stage dir, so `build_switch_nro.sh --stage-dir X` and the documented
  `cmake --build build-switch --target switchpkg` silently disagree.
- `verify_shaders.py` covers only the **30 of 97** shipped shaders (it iterates
  `lighting_manifest.json`), so "package will not use stale lighting shaders"
  overstates the guarantee.
- `WOWEE_SWITCH_RUNTIME`/`_PHASE_WINDOW` doc comments reference `CHANGELOG` entries
  and a PS4 `extract_ps4.cpp`; `extract_switch.cpp:65-67` `mirrorBundledData()` is
  now a comment-only stub.

---

## Things that are correct — don't "fix" these

Worth recording so a later reader doesn't re-litigate them.

**Vulkan / WSI.** Verified against the linked binary
(`build-switch/wowee.elf`, Mesa **25.0.7 (git-96e6e7bb05)**, `vk_icdGetInstanceProcAddr`
@`0x125060`, `wsi_CreateViSurfaceNN` @`0xfeab0`):

- The loader contract is correct — ~120 trampolines route through
  `vk_icdGetInstanceProcAddr`, `vkCreateInstance` is called from exactly one site,
  and the `.inc`'s instance-vs-device split matches NVK's single flat table, so no
  recursion or aliasing. **The `.inc` is provably complete**: a missing trampoline
  would be a link error, and the ELF links.
- `VK_KHR_surface` + `VK_NN_vi_surface` only — exactly the two required, nothing
  NVK lacks, no debug/validation layer requested. Both present in the driver's
  tables. `VK_KHR_swapchain` on the device side, verified advertised.
- `apiVersion` `VK_API_VERSION_1_1` vs driver 1.4 — legal (request ≤ support).
- `VkViSurfaceCreateInfoNN` sets only `.window`, and that is **correct** for this
  nxvk: `vulkan_vi.h:27-32` declares only `{sType, pNext, flags, window}` and
  `wsi_CreateViSurfaceNN` reads only `.window` (`wsi_switch.c:1085-1104`).
  Likewise **`nwindowSetImageParameter` is NOT missing** — nxvk owns the window and
  calls `nwindowConfigureBuffer`/`Dequeue`/`Queue`/`SetSwapInterval` itself.
- Every `VkSwapchainCreateInfoKHR` field matches this driver's actual caps:
  the only format/colorSpace pair offered is `B8G8R8A8_UNORM` + `SRGB_NONLINEAR`;
  `supportedUsageFlags = 0xDF` ⊇ the requested `0xD0`; `compositeAlpha=OPAQUE`;
  `presentMode=FIFO`. (Validation is still absent — see HIGH above.)
- **First-frame sequencing is sound.** Slot fences are created
  `VK_FENCE_CREATE_SIGNALED_BIT`; the non-MSAA scene pass clears the swapchain
  image straight to `VK_IMAGE_LAYOUT_PRESENT_SRC_KHR` (`:2150-2157`);
  `nextAcquireSemaphore_` + per-image swapping avoids handing a signalled semaphore
  to `vkAcquireNextImageKHR`; `retainedFrameImage_` preserves ownership when
  recording fails; the one-frame deferred present is primed by a normal flip;
  acquire is bounded at 2 s instead of `UINT64_MAX` (`:3231`).
- `resetFrameSyncState()` correctly re-makes all semaphores unsignalled after
  `vkDeviceWaitIdle` (`:3124-3141`) — the classic reuse hazard is handled.
- MSAA is forced to 1× (`:1889-1944`), side-stepping NVK's known MSAA gap.
- `NVK_I_WANT_A_BROKEN_VULKAN_DRIVER` ordering is right: `system_switch.cpp:276`
  runs from `initSystem()` at `main.cpp:176`, before `app.initialize()` at `:293`.

**No PS4/SDL3 leakage.** No `GNM`/`gnm_`/`sce*`/`orbis` symbol or include anywhere
in `src`/`include`/`cmake`. The `WOWEE_PS4` blocks are nested *inside*
`#ifdef WOWEE_SWITCH` and additionally guarded (`renderer.cpp:1360-1395`,
`vk_context.cpp:3363-3540`), so they compile to nothing. No SDL3 in the tree.
`ORBIS_PAD_*` are just constant names in the PS4-shaped input compat header.

**HID.** `hidInitialize()` is called exactly once (`input_switch.cpp:729`, from
the single call site `core/window.cpp:79`), and it runs *after*
`appletInitialize()` (`system_switch.cpp:210`) which HID requires. Order is
correct: `hidInitialize` → `hidInitializeNpad` → `hidInitializeTouchScreen` →
`hidSetSupportedNpadIdType` → `hidSetSupportedNpadStyleSet` → first
`hidGetNpadStates*` next frame. The thread-safety hazard is handled correctly:
`hidReady()` (`:433-437`) gates every HID read, which is mandatory because
`hidGetNpadStates*` and `hidGetTouchScreenStates` **diagAbort** (process-kill)
rather than return when the shared memory is unmapped. Polling is main-thread
only — no HID race, no cross-thread `SDL_PushEvent`. **No controller attached**
degrades gracefully (0 samples, walk keys cleared, ImGui gamepad nav off, app
runs).

**Keyboard/mouse delivery.** Neither a real SDL nor a callback — a hand-rolled
`std::deque<SDL_Event>` (`:185`) that `pumpInput()` fills and the client's normal
`SDL_PollEvent` loop drains, so all downstream consumers are unchanged. Text input
splits at UTF-8 boundaries correctly (`input_switch.cpp:1050`). Coordinates are
normalised then scaled into client pixels (`s_displayW/H` = 1280×720), kept in sync
by `setInputDisplaySize()` from `window->getWidth()` every frame. Touch units:
the code assumes 1280×720 raw and the Switch HID touchscreen *is* the physical
1280×720 panel, so this is right for this hardware (the "640×360" concern doesn't
apply).

**Networking.** `socketInitializeDefault()` is called once, guarded by
`g_initialised`, before `enterResourceRoot()` and `Application::initialize()`;
`socketExit()` is reached on every exit path via `SwitchSystemGuard`. Readiness
uses `select()` with a correct `FD_SETSIZE` guard (`:190-217`). **No TLS is needed**
and none is required — the realm list arrives as a `REALM_LIST` opcode (`0x10`)
response over the *same* TCP connection after SRP succeeds. `grep` for
`https://`/`SSL_`/`libcurl`/`wolfssl` finds only comments and chat-link text, so
`crypto_shim.cmake:46-50`'s "no TLS is provided" does not bite. **No config file
must be hand-created to log in** — there is a real UI (hostname/port fields +
libnk on-screen keyboard).

**Build.** All 441 `WOWEE_SOURCES` entries, 108 headers, the 8
`switch/compat/src/*.cpp`, 12 OpenSSL compat headers, `switch/zlib/uncompr.c`,
`switch/compat/cxx20/*`, `switch/third_party/nxvk/nvk_compat.c`, and all
`tools/asset_extract/*.cpp` resolve. `extern/{glm,imgui,StormLib,lua-5.1.5,vk-bootstrap,nlohmann}`
are vendored and git-tracked (no `.gitmodules`), so a clean clone has them.
`src/platform/switch/*.cpp` is correctly glob-gated with `imgui_impl_switch.cpp`
excluded from the glob and re-added to `imgui` — no duplicate, no omission. A
non-Switch host build silently drops nothing (the one `platform/switch/` include
outside that directory is `#elif defined(WOWEE_SWITCH)`-guarded).
`.gitattributes` forces `eol=lf` for `*.sh`/`*.py`/`*.cmake` and all six switch
scripts are CRLF-free on disk. No `/opt` hardcode in any build or packaging file —
`switch.toolchain.cmake:20-26` reads `ENV{DEVKITPRO}` and `FATAL_ERROR`s if unset.
No developer-machine path appears anywhere in build or packaging.

---

## Recommended order of work

**Before the hardware run** — each is small, and together they make the run
*diagnosable*, which is the precondition for fixing anything else:

1. **Diagnostics first.** BLOCKER 4 (`showStartupError` must show its text),
   HIGH crash-reporter (install handlers unconditionally), HIGH loader-hang
   (log before sleeping), and consider `WOWEE_LOG_LEVEL=DEBUG` for the first run.
2. **BLOCKER 1** — delete the redundant `waitForGrainRelease()` gate.
3. **BLOCKER 2** — one-line `WOWEE_CONFIG_ROOT` fix; recovers ~12 silently
   dropped config files.
4. **BLOCKER 3** — route the three `/data/wow_ps/...` literals through
   `writableRoot()`, including the two user-facing error strings.
5. **HIGH sockets** — set `sin_len`; add a `setsockopt`/`ioctl` fallback chain;
   mirror the PS4 adapter's test.
6. **HIGH heap** — drop `__nx_heap_size` to the devkitPro range and stop lying
   about `_SC_PHYS_PAGES`.
7. **HIGH `appletHook`** — suspend/resume/focus + expose `g_exitRequested`.
8. **HIGH build** — `${Python3_EXECUTABLE}`, `chmod +x` the scripts, and turn the
   `PRE_LINK` staging into an `add_custom_command(OUTPUT ...)` target so asset
   edits actually re-stage.

**Then, once it runs:** the MEDIUM list — thread stacks (miniaudio's job thread
first), the 512 MiB probe throttle, network-status check, integrity-hash paths,
tap-to-click, `addons` staging mismatch, and the two red `package_staging` tests.

**Also worth reconciling:** the four-way contradiction about whether assets live
in a romfs. Pick side-by-side **or** romfs, then fix `README.md:50-59`,
`BUILD_SWITCH.md:77-98`, and the `romfs:/` candidate at
`system_switch.cpp:459-474`. Note that `package.sh:41-42` currently *tolerates* a
missing `wowee-data` with only a warning — which, given BLOCKER 1 in the build
section, guarantees the "Required bundled resources are missing" applet.