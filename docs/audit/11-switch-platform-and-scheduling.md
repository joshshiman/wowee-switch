# Audit 11 — Switch platform integration & system-level performance

Branch: `perf/switch-audit`. Domain: the parts of the port that touch the OS —
CPU/GPU clock control, boost, core affinity and scheduling, worker-thread counts,
the main thread, SDL/window integration, present/VideoOut, the audio thread, the
toolchain, and always-on diagnostics.

Method: read `wowee/src/platform/switch/**`, `wowee/include/platform/switch/**`,
`core/window.cpp`, `core/application.cpp`, `audio/*`, `cmake/switch.toolchain.cmake`,
`CMakeLists.txt` (Switch sections), plus the vendored libnx headers under
`/opt/devkitpro/libnx/include/switch/`. No hardware was run for this audit —
findings are static, and anything that depends on Horizon behaviour is marked.

## Headline

**There is no clock, boost, or affinity code anywhere in the port.** A repo-wide
search for `clkrst`, `apm`, `pcv`, `appletSetCpuBoostMode`,
`apmSetPerformanceConfiguration`, `svcSetThreadCoreMask`, `SetThreadCoreMask`,
and `sched_setaffinity` returns **zero** call sites. The title runs at whatever
clocks APM hands an Application/applet and never asks for anything else.

The game is **GPU-bound** (~7–15 FPS; FINDINGS Run 49), and — critically —
**the Switch driver reports no usable GPU timestamps** (`validBits=0`,
`period=0` → `gpuTimingStatus=uncalibrated-switch`,
`rendering/vk_context.cpp:1598-1600`). So the one number that would tell you which
GPU pass to cut does not exist. Every remaining tuning decision is made blind on
the GPU side.

Consequence for this audit: **the OS-clock surface is mostly a dead end, and the
most attractive-looking knob (CPU boost) is actively harmful.** The honest
opportunities are (a) launching in the right mode, (b) toolchain code-gen, (c)
thread-count/affinity hygiene, and (d) trimming always-on diagnostics. None of
these will move the GPU-bound frame time much; they are worth doing because they
are cheap, not because they are large.

---

## Clear wins

### W1. Do **not** enable CPU boost mode — it throttles the GPU
- Evidence: libnx `apm.h:18-23` — `ApmCpuBoostMode_FastLoad` "*Boost CPU.
  Additionally, throttle GPU to minimum*". `ApmCpuBoostMode_Type2` also only
  lowers GPU. Only values 0/1 are reachable through `appletSetCpuBoostMode`
  (`applet.h:563-567`), and via APM only the FastLoad path raises CPU.
- There is no code path that calls it today (grep: 0 hits), which is **correct**.
  Record it so a later "let's add boost" pass does not regress a GPU-bound game
  into a GPU-starved one.
- Impact: prevents a regression (would be negative). Quality: certain. Risk: none
  (documentation/no-op). Quick win. **Switch-gate: yes** — desktop has no APM.

### W2. Toolchain: code-gen for Cortex-A57 specifically
- Evidence: `cmake/switch.toolchain.cmake:55-58` sets
  `-march=armv8-a+crc+crypto -mtune=cortex-a57`. `-mtune` only affects scheduling;
  instruction selection stays generic `armv8-a`. There is **no `-mcpu`**, so the
  A57's dual-issue/micro-arch is never exploited beyond scheduling.
- Replacing/adding `-mcpu=cortex-a57+crc+crypto` (or `-mcpu=cortex-a57+fp+simd+crc+crypto`)
  turns on A57 instruction selection as well as tuning.
- NEON is already on (`armv8-a` implies `+simd`); no action. `-O3` is already set
  for Release (`CMakeLists.txt:976`), `--gc-sections` already on
  (`switch.toolchain.cmake:60-61`).
- Impact: low-medium (GPU-bound, but pure CPU cost like culling/animation/packet
  parsing benefits). Quality/risk: **low risk, but a flag change needs a clean
  configure** — `CMAKE_CXX_FLAGS_INIT` only applies to a fresh `build-switch/`
  (AGENTS.md). Quick win. **Switch-gate: yes** — lives in the Switch toolchain.

### W3. Trim always-on diagnostics that are forced loud on Switch
- Evidence: `core/application.cpp:1353-1359` forces `frameProfileEnabled_ = true`
  on Switch, so every 5 s the loop emits the multi-hundred-field `[WORLD_PERF]`
  line (`:2066-2157`), plus `[LOCAL_PERF]` (`:2061`) and `[WORLD_SCENE]`
  (`:2163-2178`), each built through the logger's `operator<<` streaming at
  `WARNING`. First 6 frames also emit a per-frame breadcrumb (`:1437-1441`).
- These are the only per-pass CPU data the hardware loop has (FINDINGS Run 48),
  so they are *load-bearing* for debugging — but they are diagnostic scaffolding,
  not feature code, and the `[WORLD_PERF]` line formats ~120 fields on the frame
  that crosses the 5 s boundary. At 7 FPS that is negligible on average but a
  measurable formatting burst.
- Impact: low. Quality: keep the data, consider throttling the *formatting*
  (build the line only when a counter trips, not every sample) and gating the
  chattiest lines behind a boot-time flag. Risk: low. Quick win.
  **Switch-gate: partial** — the `#ifdef WOWEE_SWITCH` block already scopes it.

### W4. Launch in Application (title-override) mode — the biggest OS-level lever
- Evidence: `system_switch.cpp:220-232` detects applet mode
  (`AppletType != Application || totalMemory < 1 GiB`) and logs
  `APPLET MODE (Album) - 453 MB RAM limit!` with the fix ("Hold R on any game for
  Title Override!"). `cpu_memory.hpp:38-40` then budgets 448 MiB vs 3328 MiB.
- This is not an FPS change (`/switch/wowee/` is 74 MiB and runs either way), but
  the 448 MiB cap drives every headroom gate the port has fought
  (FINDINGS Runs 44, 46). It is already documented to the user in the boot log;
  the README should state it as the required launch mode.
- Impact: high on stability/headroom, not on frame time. Quality: certain.
  Risk: none (doc). Quick win. **Switch-gate: yes.**

---

## Measure first (GPU-bound ⇒ cannot assume CPU fixes help)

### M1. Worker-thread count and core affinity — no affinity is set anywhere
- Evidence: `core/application.cpp:1348-1351` explicitly *declines* to pin the main
  thread, documenting that OS threads inherit their creator's affinity (a
  Linux-specific concern). On Horizon there is **no affinity set at all**.
- `std::thread::hardware_concurrency()` on Switch resolves through
  `switch/third_party/nxvk/nvk_compat.c:57-78` (`popcount(core_mask)` from
  `svcGetInfo(InfoType_CoreMask)`), i.e. the number of cores Horizon grants the
  process — typically **3** (core 3 is reserved for the system). All the port's
  pools size from it:
  - `core/thread_pool.hpp:82-90` → `hw-1` (min 2): ~2 frame workers
  - `rendering/terrain_manager.cpp:115-118` → hardcoded **2** on Switch
  - `rendering/m2_renderer.cpp:520-525` → `max(1, (hw-1)/2)`: 1
  - `rendering/wmo_renderer.cpp:292-297` → `max(1, (hw-1)/4)`: 1
  - `rendering/character_renderer.cpp:363-368` → `max(1, (hw-1)/4)`: 1
  - plus `ioWorkers()` = 2 (`thread_pool.hpp:59-62`), the world-socket async
    thread (`network/world_socket.cpp:384`), the audio device thread, and the
    main-loop watchdog (`application.cpp:1380`).
- **Sum: ~9–10 long-lived threads on a ~3-core budget**, sharing cores with the
  main thread and the GPU driver's submit thread, with default priority and no
  QoS. libnx exposes `svcSetThreadCoreMask(handle, preferred_core, affinity_mask)`
  (`/opt/devkitpro/libnx/include/switch/kernel/svc.h:584`) to place them, and
  `svcGetThreadCoreMask` to read the current mask — nothing in the port uses either.
- Why measure first: the frame time is GPU execution + present back-pressure
  (FINDINGS Run 49: per-pass CPU sums to ~10–25 ms against a ~400 ms GPU frame).
  Oversubscription will not show up until the GPU path is fast enough to make CPU
  the critical path. The measurable experiment: pin the terrain/M2/WMO anim
  workers to a fixed core subset, keep the main thread off that subset, and read
  `[WORLD_PERF] renderMeanMs` / `otherAndPacingMeanMs` (application.cpp:2096-2098)
  before and after.
- Impact: low-medium now, potentially medium later. Quality: medium (affinity is
  easy to get subtly wrong; a pin that starves the main thread is worse than none).
  Risk: medium. Larger. **Switch-gate: yes.**

### M2. GPU clock / APM state is unobserved and probably unhangable
- Evidence: no `apm`/`clkrst` calls. libnx offers `apmInitialize` +
  `apmSetPerformanceConfiguration` (`apm.h:26,48`) and `clkrstSetClockRate`
  (`clkrst.h:28`), but `clkrst` is a sysmodule-level service (`clkrstInitialize`,
  `clkrst.h:17`) and an Application/applet is normally denied it; `apm`
  configuration changes are also generally refused to non-system processes.
  Present mode is `FIFO` (`vk_context.cpp:1482-1488, 2969-2975`).
- What *is* cheaply available and worth adding: call `apmGetPerformanceMode` /
  `apmGetPerformanceConfiguration` once at startup and log the result, so the
  audit can tell whether the GPU is sitting at the handheld floor (307–384 MHz)
  or has been raised. Without it the GPU clock is a blind spot.
- Note: `apmGetPerformanceMode` (`apm.h:41`) and `appletGetPerformanceMode`
  (`applet.h:2762`) are query-only and require no privilege.
- Impact: diagnostic (enables every later GPU decision). Quality: high, risk: low.
  Quick win. **Switch-gate: yes.**

### M3. LTO and `-ffast-math`
- Evidence: neither is present (`switch.toolchain.cmake:55-61`; `CMakeLists.txt:970-978`).
  `-fno-omit-frame-pointer` is passed unconditionally (`CMakeLists.txt:971`),
  costing a general-purpose register everywhere even in Release.
- `-ffast-math` on a WoW-derived float math stack is medium risk (it can change
  damage/position math); the game is GPU-bound, so the upside is small.
  LTO is a larger change against statically-linked devkitA64/nxvk archives and
  `--gc-sections`; real risk of a link failure for marginal gain.
  `-fno-omit-frame-pointer` is a cheap, safe release-only removal (keep it in
  Debug) but costs debuggability of the very backtraces this project relies on.
- Impact: low. Quality: medium/risky. Risk: medium. Larger. **Switch-gate: yes.**

### M4. Present/vsync path
- Evidence: vsync defaults true (`application.cpp:275`), main loop sleeps to a
  16.67 ms deadline when vsync is on (`application.cpp:2024-2031`); present mode
  is FIFO. At 7–15 FPS the sleep never fires, so it is not a busy-wait cost.
- A GPU-bound scene cannot be helped by disabling vsync (it would only allow
  tearing above the refresh rate). No action recommended; recorded so it is not
  re-tried.

---

## What is already correct (do not "fix")

- **SDL is bypassed entirely on Switch.** `core/window.cpp:65-93` never calls
  `SDL_Init`; a hand-rolled shim provides `SDL_PollEvent`/`SDL_GetTicks`/
  `SDL_Delay` (`input_switch.cpp:1222-1242`) over HID. There is no SDL overhead to
  remove.
- **Tracy/`ZoneScoped` instrumentation is compiled out.**
  `include/core/profiler.hpp:2-12` expands all `ZoneScopedN` macros to nothing
  unless `TRACY_ENABLE` is defined, and it is not defined in the Switch build.
  The ~15 `ZoneScopedN` call sites cost zero.
- **The audio thread does not spin.** `devWrite` blocks in
  `audoutPlayBuffer` (`audio_backend_switch.cpp:194`), which both submits and
  waits for hardware consumption, pacing the miniaudio device thread; it carries
  an explicit 2 MiB stack (`audio_engine.cpp:224`). Nothing to change.
- **No per-frame debug logging on the hot path** beyond the Switch perf block in
  W3: `[WOWEE_PAD]`/`[WOWEE_KEYTRACE]`/`[WOWEE_ACT]`/`[WOWEE_OVR]` are all gated
  behind trace env vars or one-shot action sites (grep hits in
  `input_switch.cpp:842`, `lua_engine.cpp:10064+`, `lua_action_api.cpp:2124`).
- **`pumpSystemEvents()` calls `appletMainLoop()` once per frame**
  (`system_switch.cpp:608-621`) and does no allocation — cheap.

---

## Ranked shortlist

| # | Item | Impact | Risk | Effort | Switch-gate | Evidence |
|---|------|--------|------|--------|-------------|----------|
| 1 | Require/enforce Application launch mode (title override); document in README | High (headroom) | None | Quick | Yes | `system_switch.cpp:220-232`, `cpu_memory.hpp:38-40` |
| 2 | Log `apmGetPerformanceMode`/`appletGetPerformanceMode` at boot | Diagnostic (unblocks GPU work) | Low | Quick | Yes | `apm.h:41`, `applet.h:2762` |
| 3 | `-mcpu=cortex-a57+crc+crypto` in toolchain (+ clean configure) | Low-Med | Low | Quick | Yes | `switch.toolchain.cmake:55-58` |
| 4 | Record "no CPU boost — it throttles GPU"; keep boost off | Prevent regression | None | Quick | Yes | `apm.h:18-23`, `applet.h:563-567` |
| 5 | Throttle `[WORLD_PERF]`/`[WORLD_SCENE]` formatting | Low | Low | Quick | Partial | `application.cpp:1353-1359, 2066-2178` |
| 6 | Pin heavy worker threads with `svcSetThreadCoreMask`; rebalance counts | Low-Med (later) | Med | Larger | Yes | `thread_pool.hpp:82-90`, `terrain_manager.cpp:115-118`, `m2_renderer.cpp:520`, `wmo_renderer.cpp:292`, `svc.h:584` |
| 7 | Release-only `-fno-omit-frame-pointer` drop; consider LTO/`-ffast-math` | Low | Med | Larger | Yes | `CMakeLists.txt:970-978` |

Items 1–5 are the clear wins / cheap diagnostics. Item 6 is the only remaining
scheduling lever and is explicitly gated on first moving the GPU off the critical
path (or on gaining GPU timestamps); item 7 is speculative and low-yield for a
GPU-bound title.
