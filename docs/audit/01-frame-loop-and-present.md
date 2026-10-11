# Audit 01 — Frame loop, swapchain/present, GPU synchronization and CPU/GPU pacing

Branch: `perf/switch-audit`. Domain: the end-to-end frame loop, acquire/present,
frame sync, upload batching and fences, CPU↔GPU pacing, double/triple buffering,
per-frame resource churn, vsync/FIFO.

Method: static read of `wowee/src/core/application.cpp`, `core/window.cpp`,
`main.cpp`, `rendering/vk_context.{cpp,hpp}`, `rendering/renderer.cpp`,
`rendering/vk_buffer.cpp`, `rendering/vk_memory_choice.hpp`, plus the upload-batch
call sites (`terrain_manager.cpp`, `entity_spawner_processing.cpp`,
`character_renderer.cpp`, `widget_renderer.cpp`, `world_loader.cpp`). No console
run — every claim is anchored to a line; anything that depends on runtime state is
filed under *measure first*. Companion to `docs/audit/11` (platform/scheduling),
`docs/audit/06` (memory), `09` (bandwidth).

Ranking vocabulary: **clear win** = high confidence and low risk from the code
alone; **measure first** = plausible, but the number depends on runtime state that
must be read from a log line before committing.

---

## 0. Device facts that decide everything below (switch build only)

`VkContext::createLogicalDevice()` has a Switch-specific branch
(`rendering/vk_context.cpp:799-847`) that hardcodes:

| Capability | Switch | Consequence |
|---|---|---|
| `VkDevice` queues | **1** (graphics), `transferQueue_ = VK_NULL_HANDLE`, `hasDedicatedTransfer_ = false` (`:832-835`) | Every upload and every frame submit share **one** queue. A synchronous upload wait also waits on all prior frame work. |
| `timelineSemaphoreSupported_` | **false** (`:836`) | The frame ring uses **binary fences**, not the timeline (the timeline branch at `:3226-3236` is dead on Switch). |
| `synchronization2Supported_` | **false** (`:837`) | All barriers go through the legacy fallback. |
| `hostImageCopySupported_` | **false** (`:839`) | Every texture upload is staged: CPU buffer → GPU buffer → image. |
| present mode | `VK_PRESENT_MODE_FIFO_KHR` (`:1399`) | Fixed. |
| swapchain images | `minImageCount = 3`, driver always makes 3 (`:1388`, FINDINGS §7) | Display is triple-buffered. |
| frame ring | `MAX_FRAMES_IN_FLIGHT = 2` (`include/rendering/vk_context.hpp:27`; `renderer.hpp:483 MAX_FRAMES = 2`) | CPU ring is double. |
| deferred present | **off** (`:1300-1317`) | Present is synchronous every frame. |

So on Switch: **one queue, binary fences, synchronous present, 2-deep CPU ring,
3-deep scanout.** `WOWEE_VK_ASYNC_UPLOAD_QUEUE` (the transfer-queue experiment,
`vk_context.cpp:4253-4260`) is a **no-op on Switch** — the queue does not exist.
Record that so nobody spends a round on it.

---

## 1. How a frame is paced end-to-end

Main loop, `core/application.cpp:1430-2031`:

1. `beatWatchdog()`, `Logger::flushIfStale()` (`:1435-1446`).
2. **Frame cap**: if `window->frameCap() > 0`, sleep to `1/cap` before taking
   deltaTime (`:1470-1479`). Default cap is 0 (`window.hpp:84`); the settings panel
   can set it (`settings_panel.cpp:1180`, `game_screen.cpp:626`).
3. `pumpSystemEvents()` + `pumpInput()` (`:1510-1511`), `SDL_PollEvent` loop.
4. `update(deltaTime)` (`:1924-1926`) — in-world this drains the entity spawner,
   spawn/equipment queues, quest markers, terrain streaming, etc.
5. `render()` (`:1950-1951`):
   - `prepareGlueScene`, then `runRenderStage("beginFrame", renderer->beginFrame)`
     (`:4776-4789`);
   - `renderWorld` (IN_GAME), `renderHUD`, `addonWidgets`;
   - `runRenderStage("endFrame", renderer->endFrame)` (`:5655`).
6. `window->swapBuffers()` (`:1998`) — **a no-op on Switch** (`window.hpp:45`
   "Vulkan presents in Renderer::endFrame()").
7. device-lost check (`:2014-2017`).
8. **Pacer**: `deadline = frameStart + 16 667 µs` when vsync, else 4167 µs;
   `sleep_until(deadline)` (`:2019-2031`). At 7-15 FPS the deadline is always in
   the past, so **this sleep never fires in-world** (matches audit 11 §M4). It is
   not a cost and not a cap.

`VkContext::beginFrame()` (`rendering/vk_context.cpp:3203-3450`):

- Waits the current slot's **binary fence** with a 5 s timeout (`:3238`). This is
  the only per-frame GPU wait in `beginFrame`.
- `runDeferredCleanup(currentFrame)` (`:3262`) — frees resources whose deferred
  frees were queued two frames ago.
- `readGpuTimings` (`:3269`) — **no-op on Switch** (`gpuTimingSupported_` false,
  `:1590`; `readGpuTimings` returns at `:1653`). `gpuMark()` is likewise a no-op.
- `vkAcquireNextImageKHR` with a 2 s timeout (`:3285-3290`). The 2 s is a timeout,
  not a cost.
- Reset + begin the frame command buffer (`:3380-3394`).
- If any upload batch is in flight, record a `TRANSFER_WRITE → MEMORY_READ`
  barrier into the frame command buffer (`:3412-3430`). **Same-queue uploads are
  ordered to the frame by this barrier, not by a CPU wait** (the `crossQueue`
  `waitAllUploads()` at `:3415` cannot fire on Switch).

`VkContext::endFrame()` (`rendering/vk_context.cpp:3726-3990`):

- `vkEndCommandBuffer` (`:3742`).
- `vkResetFences(frame.inFlightFence)` + `vkQueueSubmit(graphicsQueue, ...)` which
  signals `renderFinishedSemaphores_[imageIndex]` and the fence (`:3798-3811`).
- **Present**: `deferredPresent` is `ps4DeferredPresentEnabled() && images>=3`
  (`:3898`); `ps4DeferredPresentEnabled()` returns false unless
  `WOWEE_VK_DEFER_PRESENT=1` (`:1300-1317`). So the `else` branch runs
  `vkQueuePresentKHR(presentQueue, …)` **synchronously, in the same frame**
  (`:3916-3942`). `deferredPresentValid_`/`_Primed_` are never set on this path,
  so the `flushDeferredPresent()` at `:3924` is skipped and the very first present
  goes straight to `:3936`.
- `VK_ERROR_OUT_OF_DATE_KHR` → `swapchainDirty` (`:3984-3987`); the spurious
  OUT_OF_DATE containment lives in `beginFrame` (`:3307-3336`).
- `currentFrame = (currentFrame + 1) % 2` (`:3989`).

**Net shape:** `frame_k` = CPU update + CPU record + GPU execute, and because the
present is synchronous, the CPU does not start `frame_{k+1}` until the present of
`frame_k` returns. The 2-deep ring therefore does **not** overlap two frames while
the present blocks — the second slot only cushions the acquire/fence bookkeeping.

---

## 2. Clear wins

### W1 — Make the per-frame NPC-composite upload asynchronous (HIGH)
**Evidence.** `EntitySpawner::update()` runs every in-world frame
(`core/entity_spawner.cpp:171`, called from `core/application.cpp:4097` and
`:4292`). It calls `processAsyncNpcCompositeResults()`, which opens a batch and
then **waits for it synchronously in a destructor on every frame**
(`core/entity_spawner_processing.cpp:271-276`):

```cpp
auto* batchCtx = renderer_ ? renderer_->getVkContext() : nullptr;
if (batchCtx) batchCtx->beginUploadBatch();
struct BatchGuard {
    rendering::VkContext* ctx;
    ~BatchGuard() { if (ctx) ctx->endUploadBatchSync(); }   // <-- blocking
} batchGuard{batchCtx};
```

`endUploadBatchSync()` → `finishUploadBatch(true)` → `waitAllUploads()`
(`vk_context.cpp:4287-4288`, `:4323-4355`). On Switch there is one queue, so this
fence wait also waits for **all earlier queue work, including the previous frame's
submit**. In a populated area (city/hub, inn — see FINDINGS Run 63) that is a full
GPU pipeline drain every frame.

**Why async is safe.** `beginFrame` already records a
`TRANSFER_WRITE → MEMORY_READ` barrier for any in-flight batch
(`vk_context.cpp:3412-3430`), and same-queue submission order guarantees the
composite copy runs before the frame's draw. Staging lifetimes are already handled
by `deferStagingCleanup` + `pollUploadBatches` (`:4291-4321`). The only behavioural
change is that an NPC's composite texture can be one GPU step late, which the
spawn path already tolerates (the NPC is deferred, not dropped — `:293-307`).

**Change.** Swap the guard's `endUploadBatchSync()` for `endUploadBatch()`
(`entity_spawner_processing.cpp:275`). Expected impact: **high** in cities/inns,
**low** in empty wilderness. Quality/risk: **medium** — a one-frame texture lag on
newly composited NPCs, not a correctness change. **Quick win. Switch-gate:** keep
the sync path under `#ifndef WOWEE_SWITCH` or (better) carry the old behaviour in a
`#ifdef WOWEE_SWITCH` escape so desktop/PS4 are untouched.

### W2 — Make the per-model character upload asynchronous on Switch (MED-HIGH)
**Evidence.** `CharacterRenderer::loadModel()` batches a model's VB/IB/textures
then **waits synchronously per model on Switch** (`character_renderer.cpp:2054-2079`):

```cpp
#ifdef WOWEE_SWITCH
    if (ownUploadBatch) vkCtx_->beginUploadBatch();
#else
    vkCtx_->beginUploadBatch();
#endif
    ... setupModelBuffers / textures ...
#ifdef WOWEE_SWITCH
    if (ownUploadBatch) vkCtx_->endUploadBatchSync();   // <-- one GPU round trip per model
#else
    vkCtx_->endUploadBatch();
#endif
```

During crowded spawns (city entry, 100+ NPCs — FINDINGS Runs 47/63) this is one
full GPU round trip per newly-spawned model.

**Why async is safe.** Same argument as W1: the destination image/buffer is
referenced only by draws recorded later in the frame, and the same-queue + barrier
ordering makes the copy precede the draw. The comment at `:2051-2053` claims "a
character model is not published until this function returns" — publication is CPU
state (`models` map), which still happens synchronously; only *GPU completion* is
deferred. The rollback path already assumes async completion is provable
(`ModelRollback`, `:1979-1999`).

**Change.** Use `endUploadBatch()` on the success path; keep the existing
`finishInterruptedUploadBatch()`/`waitAllUploads()` on the failure path.
Expected impact: **medium-high** during spawn bursts, negligible when idle.
Quality/risk: **medium** — smoke-test a fresh city entry; if a model renders with
uninitialised texture the fallback is the existing white texture. **Quick win.
Switch-gate:** the code is already `#ifdef WOWEE_SWITCH`-split; change only the
Switch arm.

### W3 — Promote the frame-CPU telemetry so the block is measurable (LOW, enabler)
**Evidence.** The two lines that would show whether the present blocks and what
`beginFrame` costs are `LOG_INFO` and therefore **suppressed on a Release Switch
build** (log level pinned to WARNING, AGENTS.md):

- `[VK_FRAME_BEGIN_CPU]` `fenceMeanUs / acquireMeanUs / commandPrepareMeanUs`
  (`vk_context.cpp:3436-3446`);
- `[VK_FRAME_END_CPU]` `presentMeanUs / queueSubmitMeanUs / presentMaxUs`
  (`vk_context.cpp:3949-3958`);
- `[BEGIN_FRAME_CPU]` (`renderer.cpp:1680`).

**Change.** Emit these at `LOG_WARNING` on Switch (or a one-shot 10 s summary).
Expected impact: **none on FPS**, but it is the measurement that decides M1/M2
below. Quality/risk: **low** — a handful of throttled lines. **Quick win.
Switch-gate:** wrap the `LOG_INFO`→`LOG_WARNING` switch in `#ifdef WOWEE_SWITCH`.

### W4 — Reuse batch command buffers instead of allocating one per batch (LOW)
**Evidence.** `ensureBatchCmd()` allocates a command buffer the first time a batch
records (`vk_context.cpp:4170-4192`), and the batch's command buffer is freed on
retirement (`pollUploadBatches` `:4307`, `waitAllUploads` `:4344`). During terrain
streaming that is one `vkAllocateCommandBuffers`/`vkFreeCommandBuffers` pair per
frame, per batch. The pool was already created with
`RESET_COMMAND_BUFFER_BIT`, so the buffers are reusable.

**Change.** Keep a small per-slot ring of batch command buffers keyed by
in-flight batch, reset instead of free. Expected impact: **low** (pool churn and
one VMA-free-path sync per batch, not a GPU stall). Quality/risk: **low**.
**Quick win. Switch-gate:** optional; this is a general improvement and can be
unconditional, but a `WOWEE_SWITCH`-only version keeps desktop byte-identical.

### W5 — Document the transfer-queue dead end on Switch (doc, LOW)
`hasDedicatedTransfer_` is forced false on Switch (`vk_context.cpp:835`) and the
separate-queue path is additionally env-gated (`:4253-4260`). Record that
`WOWEE_VK_ASYNC_UPLOAD_QUEUE` does nothing on the console, so a future round does
not try to "overlap uploads on the transfer queue". No code change.

---

## 3. Measure first

### M1 — The synchronous present serializes the CPU behind the GPU (the big one)
**Evidence.** The in-tree measurement is explicit
(`rendering/vk_context.cpp:3880-3897`): *"nxvk must prove render completion before
VideoOut can consume an image. Doing that proof in the same frame's present
serialized the CPU behind the GPU and showed up as ~tens of milliseconds inside
endFrame."* Deferred present was the fix, but it is **off** because nxvk's WSI
checks out one buffer at a time (`:1300-1312`, FINDINGS §7). So today the
`vkQueuePresentKHR` at `:3936` blocks the calling thread until the frame's GPU work
finishes, and the next frame's `beginFrame` cannot start recording before that
returns.

**Consequence.** `frameTime ≈ CPU_record + GPU_execute` instead of
`max(CPU_record, GPU_execute)`. With the measured shape (CPU passes sum to
10-25 ms, FINDINGS Run 49/56/60) that is a **10-20 %** penalty near the current
~65-130 ms frames and less at 240 ms. It is not the fill bottleneck, but it is
pure lost throughput that no draw-call cut recovers.

**Confirm before investing** with W3 (read `presentMeanUs` ≈ frame time and
`fenceMeanUs` ≈ 0 ⇒ the block is real). If confirmed, the candidate designs, all
**larger changes** with the nxvk WSI constraint in mind:

1. **Record-ahead**: keep the swapchain image out of the scene entirely (the port
   already renders the world into an off-screen target at 480p — see
   `switch_scene_extent.hpp`), and split the frame so the *only* swapchain-touching
   work is the final composite. Then the next scene's CPU recording can begin
   before the composite's present blocks. High risk: touches the post-process and
   overlay split; needs careful ownership of the swapchain image.
2. **Present-the-previous-frame with a strict single-checkout invariant**: acquire
   image N, render, submit; at the *top of the next frame* present N and
   immediately acquire N+1 (never two checked out at once). This is a variant of
   the failed deferred present; only worth attempting if W3 shows the block is
   large. Mark high risk.

**Switch-gate:** mandatory `#ifdef WOWEE_SWITCH`; desktop is a different WSI.

### M2 — Raising `MAX_FRAMES_IN_FLIGHT` to 3 does not help until M1 is fixed
**Evidence.** The ring is 2 everywhere (`vk_context.hpp:27`; `renderer.hpp:483`;
`hiz_system.hpp:109`; `character_preview.hpp:173`;
`post_process_pipeline.hpp:315 DESC_SET_COUNT = 2`). `beginFrame` waits slot `k-2`
(`vk_context.cpp:3220-3238`). But because the present at `endFrame` drains the
queue, slot `k-2`'s fence is already signalled when `frame_k` starts — the second
slot is not buying overlap today.

**Change.** Budget the per-frame resources (per-frame UBOs `renderer.hpp:486-489`,
shadow images/descriptors, HiZ pyramids) for a 3rd slot. Expected impact:
**zero now**, potentially medium after M1. Quality/risk: **medium** (memory is the
port's structural risk). **Larger change, measure first, Switch-gate optional.**

### M3 — Upload backpressure thresholds and `waitAllUploads` frequency
**Evidence.** `beginUploadBatch()` blocks in `waitAllUploads()` once the backlog
reaches **8 batches / 16 MiB** on Switch (`vk_context.cpp:4135-4146`), and
`waitAllUploads()` waits a 5 s timeout on every outstanding fence
(`:4327`). While streaming, `processReadyTiles()` opens one async batch per frame
(`terrain_manager.cpp:2048-2102`). Whether the threshold actually trips in-world is
unlogged at WARNING — the `[UPLOAD_PRESSURE]` line is `LOG_INFO` (`:4143`) and so
is invisible on Release. If it trips, the frame takes a full GPU drain.

**Change.** First promote `[UPLOAD_PRESSURE]` to WARNING on Switch and count it.
Only if it fires should the thresholds be revisited — the 8/16 MiB values were
halved deliberately after the entry-burst device losses (FINDINGS Run 52), so
raising them is a stability risk, not a free win. **Measure first.**

### M4 — Per-frame command-buffer/staging churn during streaming
The streaming path is already async (good), but each frame opens a batch, records
into it, submits it and retires the previous one, so per frame there is a
`vkAllocateCommandBuffers` + `vkFreeCommandBuffers` + `vkCreateFence` +
`vkDestroyFence` (`finishUploadBatch` `:4247-4250`, `pollUploadBatches`
`:4307-4308`). A fence/command-buffer pool would remove it. Expected impact:
**low**. Fold into W4. **Measure first whether it shows up**; not worth a round on
its own.

### M5 — Where the CPU record time that the present exposes actually goes
Because M1 makes the CPU record additive, reducing it is now worth more than it
would be on a normal double-buffered game. The CPU passes are broken out in
`[WORLD_PERF]` (`application.cpp:2106-2138`: `prepareMs/shadowMs/reflectionMs/
m2Ms/charsMs/postMs/fx*Ms`). Shadow (`4-12 ms`) and reflection (`1-6 ms`) are the
largest `renderer.cpp`-side items (FINDINGS Run 49); `fx*Ms` is the widget tree.
Chase these only under the other audits' lens, but note that with M1 unresolved
they are *on top of*, not *overlapped with*, the GPU frame.

---

## 4. What is already correct (do not "fix")

- **No `vkDeviceWaitIdle` on the hot path.** Verified every call site: `renderer.cpp`
  `:498`/`:1081`/`:1295`/`:4471`/`:4540` (reset/shutdown/MSAA-change/swim-pass
  rebuild), `ui_manager.cpp:401` (shutdown), `character_preview.cpp:257`
  (shutdown), `minimap.cpp:250` and `world_map/composite_renderer.cpp:237`
  (shutdown), `hiz_system.cpp:38,51`, `footprint_renderer.cpp:86`,
  `quest_marker_renderer.cpp:134`, `terrain_renderer.cpp:319`,
  `post_process_pipeline.cpp:903,1416`, `world_loader.cpp:1411` (entry).
  None is per-frame. The per-frame waits are the slot fence (`beginFrame`) and
  `waitAllUploads` from sync batches — both covered above.
- **The 5 s fence timeout and 2 s acquire timeout are timeouts, not costs.**
  `vk_context.cpp:3233/3238/3285`.
- **Timeline semaphore, sync2 and host image copy are all correctly detected and
  disabled on Switch** (`:836-843`); the barriers correctly fall back to
  `vkCmdPipelineBarrier` (`setPipelineBarrier2Fn(nullptr)`).
- **FIFO is not the FPS cap at 7-15 FPS.** Frame time ≫ 16.67 ms, so the vsync
  sleep (`application.cpp:2024-2031`) never fires and FIFO does not throttle.
  Do not try to disable vsync (it only allows tearing above the refresh rate —
  audit 11 §M4).
- **Deferred present off is correct**, given the nxvk single-checkout WSI
  (`:1300-1312`). Re-enabling it without addressing M1's design would reintroduce
  the white-flash/device-lost storm.
- **Multithreaded secondary-buffer recording is correctly disabled on Switch**
  (`renderer.cpp:1018-1025`) — nxvk does not implement secondary inheritance. The
  inline fallback (`:1654-1665`) is the same one used elsewhere.
- **The swapchain image count is 3**; the two-image fallback in `createSwapchain`
  (`:1403-1410`) is for a driver that refuses 3 but this one does not. Nothing to
  change.
- **No per-frame buffer/image allocation** in the frame loop itself; the per-frame
  UBO is a plain `memcpy` into a mapped double-buffered range
  (`renderer.cpp:684`) and descriptor sets are sized to `MAX_FRAMES`.
- **`readGpuTimings`/`gpuMark` are no-ops on Switch** (`vk_context.cpp:1653`),
  so the GPU-timing query pools cost nothing.

---

## 5. Ranked shortlist

| # | Item | Impact | Risk | Effort | Switch-gate | Evidence |
|---|------|--------|------|--------|-------------|----------|
| 1 | NPC-composite upload: `endUploadBatchSync` → `endUploadBatch` | High (populated) | Med | Quick | Yes | `entity_spawner_processing.cpp:271-276`, `application.cpp:4097,4292` |
| 2 | Promote `[VK_FRAME_BEGIN/END_CPU]` to WARNING on Switch (measure the present block) | Diagnostic (enabler) | Low | Quick | Yes | `vk_context.cpp:3436,3949` |
| 3 | Character `loadModel`: per-model sync → async on Switch | Med-High (spawns) | Med | Quick | Yes (already split) | `character_renderer.cpp:2054-2079` |
| 4 | Restore CPU/GPU overlap despite blocking present (record-ahead / strict single-checkout) | High (10-20 % of frame) | High | Larger | Yes | `vk_context.cpp:3880-3897,3936`, `:1300-1317` |
| 5 | Reuse batch command buffers/fences instead of alloc+free per batch | Low | Low | Quick | Optional | `vk_context.cpp:4170-4192,4307-4308,4344-4250` |
| 6 | Promote `[UPLOAD_PRESSURE]` + count it; only then revisit the 8/16 MiB watermark | Low-Med | Med (stability) | Quick→Med | Yes | `vk_context.cpp:4135-4146`, `terrain_manager.cpp:2048-2102` |
| 7 | Raise `MAX_FRAMES_IN_FLIGHT` to 3 | Zero until #4 | Med (memory) | Larger | Optional | `vk_context.hpp:27`, `renderer.hpp:483` |

Items 1-3 and 5 are actionable from the code alone. Item 2 is the cheap
measurement that decides whether item 4 is worth its risk: if a run shows
`presentMeanUs ≈ frame time` and `fenceMeanUs ≈ 0`, the CPU/GPU serialization is
real and item 4 becomes the single largest frame-loop lever; if not, item 4 drops
to low priority and the remaining work is upload churn (1/3/5) on top of the
GPU fill work owned by audits 06/07/09.
