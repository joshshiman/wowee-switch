# Switch performance audit — master report

**Branch:** `perf/switch-audit` (off `main` @ `3aeef86`)
**Date:** 2026-10-10
**Scope:** rendering, graphics, memory, and frame pacing on the Nintendo Switch
in handheld mode.
**Inputs:** 11 parallel deep-read audits under `docs/audit/01..11`. This file is
the synthesis: what is really costing frames, what to do, in what order, and what
to measure before committing.

> Measure-first culture applies. Everything marked **[verify]** has a runtime
> dependency that a single console round can settle; everything else is a static
> code finding with a file:line anchor. Prior work is in `docs/FINDINGS.md` — do
> not re-run any of its experiments.

---

## 0. The one-paragraph diagnosis

The port is **GPU fill-bound at a 853×480 off-screen world target**, with a
secondary **main-thread hitch** regime while streaming. The big obvious levers
are already spent (shadows/volumetric/bloom forced off, 480p scene, M2/WMO
distance cuts, NPC radius 90, clutter 25). What remains is **work that is still
executed for no visible result** (shadow-map sampling with no casters, an
unconditional water refraction copy, a second skybox model, per-frame GPU
drains) and **memory paths that churn and fragment** (per-slice staging
allocation, unbounded texture caches, an 8× texture expansion because hardware
BC is disabled). None of these is a shader rewrite; most are one-to-few-line
changes or small, well-scoped refactors.

---

## 1. Master priority table

Impact = expected effect on sustained FPS / stability. Effort = diff size.
Risk = visual or stability risk. `[verify]` = settle with one measurement round.

| # | Change | Domain | Impact | Effort | Risk | Evidence |
|---|--------|--------|--------|--------|------|----------|
| **1** | **Gate shadow sampling on "casters exist"**, not `shadowsEnabled` — write `shadowParams.x` from `shadowLevelDrawsCasters(shadowQuality_)` | shaders / all | **HIGH** | 1 line | LOW | `renderer.cpp:596-598` vs `:4722`, `shadow_quality.hpp:48`; `character.frag.glsl:410,145-168`, `m2.frag`, `terrain.frag`, `wmo.frag` |
| **2** | **Gate water refraction capture + continuation pass on visible water** (`hasSurfaces()`) | post / water | **HIGH-MED** `[verify]` | small | LOW | `renderer.cpp:3530-3581`, `water_renderer.cpp:1300-1466` |
| **3** | **Disable / bake the second skybox M2** (`skyboxModelRenderer_`) on Switch — it draws 18 additive full-screen layers on top of the procedural sky | M2 / sky | **HIGH at sky** | small | LOW-MED | `renderer.cpp:3443-3444`, `m2_renderer_render.cpp:1354-1372` |
| **4** | **Per-frame NPC-composite upload: `endUploadBatchSync` → `endUploadBatch`** (removes a full GPU drain every frame in cities/inns) | frame loop | **HIGH (populated)** | 1 line | MED | `entity_spawner_processing.cpp:271-276`; called `application.cpp:4097,4292` |
| **5** | **Texture caches: enforce a byte budget + LRU eviction** (4 caches default to ~20 GiB of budget on a 1.8 GiB heap; `lastUse` recorded but never used) | textures / memory | **HIGH (stability)** | medium | LOW | `terrain_renderer.cpp:219,776`; `m2_renderer.cpp:1106`, `m2_renderer_instance.cpp:809`; `wmo_renderer.cpp:408,3145`; `character_renderer.cpp:499,898` |
| **6** | **Terrain mega-buffer: roll back `megaVBUsed_`/`megaIBUsed_` on tile unload** (currently one-shot → after ~3.5 tiles every tile takes 512 per-chunk VMA allocations) | terrain | **MED-HIGH (stability/churn)** | small | LOW | `terrain_renderer.cpp:1398-1415` vs `:1471-1473` |
| **7** | **Terrain vertex/index shrink:** drop the dead `chunkIndex` byte (44→40 B) and switch indices to `uint16_t` (halves IB, doubles mega IB capacity) | terrain | MED | small | LOW | `terrain_mesh.hpp:16-34`, `terrain_mesh.cpp:220-264`; binds `terrain_renderer.cpp:1095,1158,1353,1374` |
| **8** | **M2 spatial-index rebuild is O(~19 000) and reruns on every model load; main thread blocks on it** → make it incremental/coalesced or rehash-stable | main thread | **HIGH (hitch)** | medium | MED | `m2_renderer.cpp:2385`, `m2_renderer_instance.cpp:539-607`, join `renderer.cpp:2435/2460` |
| **9** | **Hardware BC/DXT texture path** — currently force-disabled by one line; enabling gives 8× (BC1) / 4× (BC2-3) memory & bandwidth on world textures | textures / memory | **HIGH** `[verify]` | medium | HIGH | `vk_context.cpp:668` (`blockCompressionSupported_ = false`); consumer ready `blp_loader.cpp:362-417`, `vk_texture.cpp:580-639` |
| **10** | **Per-slice staging allocation** → pool/recycle staging buffers at batch retire | memory | MED | medium | LOW | `vk_utils.cpp:217,231,266`; `vk_texture.cpp:240,268,448,475`; retire `vk_context.cpp:4304-4306` |
| **11** | **Character `loadModel` waits per model on Switch** → async on the success path | frame loop | MED-HIGH (spawns) | 1 line | MED | `character_renderer.cpp:2054-2079` |
| **12** | **Terrain per-chunk params UBO (256 allocs/tile) → push constant** | terrain | MED | medium | LOW-MED | `terrain_renderer.cpp:663-691,462` |
| **13** | **Ribbons have no distance cull** (particles do) — one draw/emitter per frame | effects / M2 | MED (combat VFX) | quick | LOW | `m2_renderer_particles.cpp:460-542` |
| **14** | **Character anim radius 120 → match draw radius 90** (bones computed + uploaded for invisible NPCs) | characters | MED (CPU/bw) | 1 line | LOW | `character_renderer.cpp:2397` vs `:2882` |
| **15** | **Character opaque/transparent two-phase per frame** (currently nested per-instance → blend overdraw that grows with crowds) | characters | MED (fill) | medium | LOW-MED | `character_renderer.cpp:3107-3164` |
| **16** | **Cap concurrent spell visuals** (no global budget today; only Acherus caps at 128) | effects | MED (combat) | small | LOW-MED | `spell_visual_system.cpp:341,485,503,711` |
| **17** | **Skybox drawn first, overdrawn by everything** → draw after opaque geometry (depth write off, `z=1.0`, LEQUAL) | shaders / sky | MED-HIGH | small | LOW | `skybox.cpp:153`, `sky_system.cpp:110`, `skybox.cpp:67` |
| **18** | **Cheap cloud shader variant** (replace the wholesale skip with density gate + 2-octave texture noise) | shaders / sky | HIGH at sky | medium | MED | `sky_system.cpp:165` (current skip), `clouds.frag.glsl:36-95` |
| **19** | **M2 skeletal LOD is inert** — only `skin00` loads; distance tiers select the same mesh. Load `skin01/skin02` for real geometric LOD | M2 | HIGH (larger) | large | MED | `m2_skin_lod.hpp:8-12`, `m2_renderer.cpp:1957,2356-2360` |
| **20** | **Lua GC**: add bounded per-frame `LUA_GCSTEP` (a mid-session Lua OOM crash is on record) | main thread | MED | small | LOW | `addon_manager.cpp:900,914`, `lua_memory_budget.hpp:9` |
| **21** | **Restore CPU/GPU overlap despite blocking present** (record-ahead / strict single-checkout) | frame loop | HIGH (10-20 % of frame) | large | HIGH | `vk_context.cpp:3880-3897,3936`, `:1300-1317` `[verify]` |
| **22** | **VMA `preferredLargeHeapBlockSize` is 4 MiB** — below the documented 8 MiB "do not go lower" floor. Reconcile with a measured block ladder | memory | MED `[verify]` | small | MED | `vk_context.cpp:1134` vs `FINDINGS.md:65-66,88`, `AGENTS.md:286` |
| **23** | **Enforce/document Application (title-override) mode** — applet mode caps at 448 MiB vs 3.25 GiB | platform | HIGH (stability) | doc | LOW | `system_switch.cpp:220-232`, `cpu_memory.hpp:38-40` |
| **24** | **Add `-mcpu=cortex-a57+crc+crypto`** (only `-mtune` today; A57 instruction selection unused) | platform | LOW-MED | 1 line + reconfigure | LOW | `switch.toolchain.cmake:55-58` |
| **25** | **M2 GPU-cull resource set allocated but never used on Switch** (~1.6 MiB×2 SSBOs, pipelines, HiZ) | M2 / memory | LOW-MED (memory) | small | LOW | `m2_renderer.cpp:760-920`, `m2_renderer_render.cpp:1083-1088` |

---

## 2. The three findings that are bigger than their line count

### 2.1 Shadow sampling with nothing in the shadow map (#1)
`shadowsEnabled` is hard-wired `true` (`renderer.hpp:346`; `setShadowsEnabled`
ignores its argument, `:377`). `shadowParams.x` is written from it
(`renderer.cpp:596-598`), so the **fragment shaders run the full shadow path**
even though Switch forces shadow quality 0 (no casters; the atlas is clear-only,
clear depth 1.0 ⇒ every comparison returns "lit"). The `character.frag`,
`m2.frag`, `terrain.frag` and `wmo.frag` shaders each gate their shadow sampling
on `shadowParams.x > 0.5` (e.g. `character.frag.glsl:410`), so this is **one UBO
write fixing four fragment stages** — up to 8 `sampler2DShadow` taps + gradient
math per lit fragment, pure discarded fill that scales exactly with screen
coverage (worst in combat, which is the reported worst case). The fix already
exists as a predicate used elsewhere (`shadowLevelDrawsCasters`,
`shadow_quality.hpp:48`, used at `renderer.cpp:4722`). Visually identical.

### 2.2 Memory is the structural risk, and the texture caches are unbounded (#5, #9)
Four texture caches default to `4096 + 4096 + 8192 + 4096` entries ≈ **20 GiB of
nominal budget on a 1.8 GiB heap**. `lastUse` is recorded but never consulted for
eviction; over-budget requests return white instead of evicting. This is the
mechanism behind the "a 65,536-byte image was refused while the same bytes were
served moments later" ceiling (`FINDINGS.md:51-53`) and the white-texture
regressions. Separately, `blockCompressionSupported_` is hardcoded `false`
(`vk_context.cpp:668`), so **every world texture is expanded to RGBA8 with a
full CPU mip chain** instead of staying BC-compressed GPU-side — 8× the memory
and bandwidth for BC1 textures. The consumer path is complete; only the enable
flag and a driver-capability probe are missing.

### 2.3 A full GPU drain every frame in populated areas (#4)
`EntitySpawner::update` (every in-world frame) opens an upload batch and waits it
*in a destructor* via `endUploadBatchSync()` on Switch. With one graphics queue,
that fence wait also waits on all prior queue work including the previous frame.
Same-queue ordering already makes the async path safe (`beginFrame` records the
`TRANSFER_WRITE→MEMORY_READ` barrier at `vk_context.cpp:3412-3430`), so this is a
one-line change to `endUploadBatch()` with a one-frame texture lag on new NPCs.

---

## 3. What is already correct — do not re-open

A large fraction of the obvious work is done. Explicitly:

- **Shadows/volumetric/bloom**: forced off at startup *and* in every setting sink
  (`renderer.cpp:812-886,1031-1042`). The shadow pass still runs as a clear-only
  pass deliberately (it leaves the atlas in the sampled layout — `renderer.cpp:4707-4774`).
- **Local lights are already capped to 8 on Switch** (`switch_world_budget.hpp:25`,
  `renderer.cpp:616-623`, `nearestLocalLights`). The shader loop is `min(count,64)`
  (`terrain.frag.glsl:157`), so it runs 8. **This invalidates audit 09's #1 — do
  not chase it.**
- **Scene resolution**: 480p world target, UI/menus native, runtime-raisable
  (`switch_scene_extent.hpp:29`).
- **M2/WMO distance cuts** x0.45 / x0.6, NPC radius 90, clutter 25, WMO culling on.
- **No per-frame `vkDeviceWaitIdle`** anywhere (all 16 sites are startup/reset/
  shutdown/entry) — audit 01 verified every one.
- **No per-frame heap/buffer/image allocation** in the frame loop; per-frame UBO
  is a plain `memcpy` into a mapped range.
- **MSAA is genuinely 1×**; deferred present off is correct for nxvk's
  single-checkout WSI; multithreaded secondary recording correctly disabled;
  timeline/sync2/host-image-copy correctly detected off.
- **Particle frame budget + distance cull + pressure feedback**, bone-upload
  change detection, distance bone throttling, per-batch static facts cached.
- **FIFO/vsync is not the cap** at 7-15 FPS; the vsync sleep never fires.

---

## 4. Measurement gaps to close first (cheap, one console round)

These are ordered so a single run answers the most questions:

1. **Promote the frame-CPU telemetry to WARNING on Switch**: `[VK_FRAME_BEGIN_CPU]`
   / `[VK_FRAME_END_CPU]` (`vk_context.cpp:3436,3949`), `[BEGIN_FRAME_CPU]`
   (`renderer.cpp:1680`), `[UPLOAD_PRESSURE]` (`vk_context.cpp:4143`). If
   `presentMeanUs ≈ frame time` and `fenceMeanUs ≈ 0`, the present block (#21) is
   real and becomes the largest frame-loop lever; otherwise #21 drops in priority.
2. **Sub-time `Renderer::update`** (currently only logs the total,
   `application.cpp:4618-4622`): time the M2-animation join, char anim, lighting,
   zone audio, model cleanup — this names the 50-60 ms hitch (#8).
3. **Log APM performance mode / GPU clock** (`apmGetPerformanceMode`,
   `appletGetPerformanceMode`) — the GPU clock is currently a blind spot
   (no GPU timestamps: `vk_context.cpp:1598-1600`).
4. **Counters**: texture-cache occupancy + miss (#5), portrait composites/frame
   (C9), `[WORLD_PERF]` already gives per-pass means.

---

## 5. Suggested implementation plan (phased)

**Phase 0 — measure (1 build, no behavior change)**
Items 1-4 above. Output decides #21 and confirms the shadow fix's real size.

**Phase 1 — one-line / small cross-cutting fill wins**
#1 (shadow gate), #4 (NPC async), #11 (character async), #3 (sky M2),
#7 (terrain vertex/index — do #1/#2/#3 first, they are bigger), #13 (ribbon cull),
#14 (anim radius), #6 (mega-buffer rollback), #20 (Lua GC step), #22 (verify VMA block).
Expected: the most FPS per unit of risk in the whole audit.

**Phase 2 — memory headroom**
#5 (texture cache budget/LRU), #10 (staging pool), #25 (dead M2 cull resources),
#2 (water gate). Moves stability and removes the ceiling rather than raw FPS.

**Phase 3 — real rendering reductions**
#9 (BC texture experiment behind a probe), #18 (cheap clouds), #17 (skybox order),
#12 (terrain params push constant), #15 (character two-phase), #16 (spell budget),
then the larger geometry work #19 (skin LODs), #21 (present overlap).

**Phase 4 — platform**
#23 (mode), #24 (`-mcpu`), then scheduling/affinity only if Phase 1-3 shifts the
bottleneck off the GPU.

---

## 6. Ranked "just do these" shortlist (highest FPS per risk)

1. #1 shadow sampling gate — 1 line, cross-cutting, zero visual change.
2. #4 + #11 async uploads — 2 lines, removes per-frame GPU drains.
3. #3 sky M2 off on Switch — kills the "sky is slowest" case.
4. #2 water refraction gate — large per-frame copy when no water is visible.
5. #6 mega-buffer rollback + #7 terrain vertex/index — fixes churn + fragmentation.
6. #8 M2 spatial-index rebuild — the named main-thread hitch.
7. #14 anim radius + #20 Lua GC — cheap CPU/latency headroom.
8. #5 texture cache budgets — stops the white-texture/ceiling class.
9. #17 skybox draw order + #18 cheap clouds — sky fill.
10. #9 BC textures — the biggest single memory/bandwidth lever, but needs a probe.

---

## 7. Domain reports

| Report | Domain |
|--------|--------|
| [01-frame-loop-and-present.md](01-frame-loop-and-present.md) | frame pacing, present block, sync, upload churn |
| [02-fullscreen-passes-and-post.md](02-fullscreen-passes-and-post.md) | post, shadows, MSAA, water copy, overlay passes |
| [03-terrain.md](03-terrain.md) | terrain mesh/draws, mega buffers, clutter, streaming |
| [04-m2-models.md](04-m2-models.md) | M2 batching, sky M2, particles/ribbons, LOD, vertex packing |
| [05-wmo-buildings.md](05-wmo-buildings.md) | WMO portals, interiors, material sets |
| [06-memory-and-vma.md](06-memory-and-vma.md) | VMA, staging, fragmentation, caches |
| [07-textures-and-blp.md](07-textures-and-blp.md) | BLP decode, BC path, mip builds, caches |
| [08-cpu-main-thread-and-hitches.md](08-cpu-main-thread-and-hitches.md) | update path, streaming, Lua, UI, hitches |
| [09-shaders-and-bandwidth.md](09-shaders-and-bandwidth.md) | fragment cost, overdraw, vertex formats |
| [10-characters-and-effects.md](10-characters-and-effects.md) | characters, combat VFX, portraits |
| [11-switch-platform-and-scheduling.md](11-switch-platform-and-scheduling.md) | clocks, threads, toolchain, launch mode |

### Known corrections to the domain reports
- **09 W1 ("cap MAX_LOCAL_LIGHTS") is already satisfied on Switch** — the CPU
  caps the active count to 8 (`renderer.cpp:616-623`); the shader loops
  `min(count,64)`. Lower its priority to "done".
- **06 M1** presents VMA 4 MiB as a straight regression vs docs. In fact commit
  `19dac7c` set it deliberately with a rationale; the docs (`FINDINGS.md:65-66,88`)
  are the stale side. Treat as **[verify]**, not "revert".
- **10 C1** and **02 W1** overlap the same `shadowParams.x` finding; #1 above is
  the single fix.

---

## 8. Non-goals / parked

- **FSR scaling-blit upscale** — blocked on nxvk (`water_renderer.cpp:1312-1321`); the full-screen triangle is the supported path.
- **Multithreaded secondary-buffer recording** — nxvk lacks inheritance.
- **Transfer-queue upload overlap** (`WOWEE_VK_ASYNC_UPLOAD_QUEUE`) — no-op on Switch (one queue); do not spend a round.
- **Character instancing** (#C10) — real but CPU-side; the device is GPU-bound today.
- **Portrait caching** — already change-guarded/throttled; FINDINGS declined it with data.
- **Screenshots, minimap arrow rotation, lamp sway** — outstanding feel items, unrelated to perf.

---

## 9. Phase 1 status (implemented, independently audited, built)

Phase 1 shipped on `perf/switch-audit`: items **#1, #3, #4, #6, #7, #11, #13, #14,
#20** plus the frame-CPU telemetry promotion (measurement enabler). Files:
`renderer.cpp` (shadow gate, sky-M2 skip), `entity_spawner_processing.cpp`
(NPC-composite async), `character_renderer.cpp` (loadModel async, anim radius,
rollback hardening), `terrain_renderer.{cpp,hpp}` (mega free-list, uint16 indices,
40-byte vertex) + `terrain_mesh.hpp`/`terrain_vertex.hpp`, `m2_renderer_particles.cpp`
(ribbon distance cull), `lua_engine.{hpp,cpp}` (bounded GC step),
`vk_context.cpp` (telemetry + unconditional transfer→read barrier).

**Verification:** `cmake --build build-switch` clean (exit 0); the only warnings in
touched files are pre-existing. `verify_tls_access.py` PASS. Staged via `switchpkg`.

**Independent audit (4 reviewers, read-only):** **no blockers.** Findings applied:
- MAJOR — `beginFrame`'s transfer→read barrier was gated on `inFlightBatches_` being
  non-empty, so a render-phase upload (character preview/paperdoll path) could lack
  the dependency. Now recorded unconditionally (`vk_context.cpp`).
- MAJOR — the `ModelRollback` fix covered the batch owner but not nested callers;
  destruction is now deferred (`destroyModelGPU(*model, defer=true)`).
- MAJOR — ribbon cull diverged from the draw cull (origin vs visual-bounds center,
  raw base distance vs per-instance effective distance, a ~2× pop at Environment
  Detail < 1.0). Now mirrors `m2InstanceMaxDistSq` + cull-center/radius.
- MINOR — terrain `destroyChunkGPU` now clears the mega placement sentinel; stale
  44-byte comments corrected.

**Accepted, not fixed (noted):** the sky M2 *renderer* is still allocated on Switch
(one-time memory, the per-frame draw cost is gone); a debug-only surface-shadow
inspection view now renders magenta at quality 0 (`shadowParams.x` is the debug
key); the Lua GC step reduces but cannot eliminate a single-frame allocation burst
crossing the cap.

**Not yet done from the report:** everything in Phase 2/3 (#5 texture-cache LRU,
#9 BC textures, #18 cheap clouds, #19 skin LODs, #21 present overlap, …).

## 10. Phase 2 + Phase 3 status (deployed, audited)

**The measurement that redirected everything** (run 2026-10-10_2338, Phase 1 on
card): `frameMeanMs 83` = `update 9` + `render 74`, and `presentMeanUs ≈ 58,000`
with all CPU passes summing to ~14 ms. The CPU blocks ~58 ms in
`vkQueuePresentKHR` waiting on the GPU — the frame is **GPU-bound**, so Phase 1
(CPU-side) could not move it. `presentMaxUs` tracks load, so that is real GPU
execution, not vsync pacing. `boot.log` was 17.9 MB of one per-frame line.

**Phase 2 (`846d811`, GPU-fill cuts):** skip the quality-0 shadow clear (2.1 MB +
2 barriers/frame); MSAA floored to 1× (latent 4×-fill path); FXAA forced off (the
full 3.11 kernel, up to ~20 taps/px at 720p); water refraction copy + continuation
pass gated on `hasSurfaces()` (~9.8 MB/frame in waterless frames); the per-frame
acquire log removed. The skybox reorder was implemented then **reverted** — the
sky unit also contains depth-less celestial discs and lens flare, so deferring it
paints the sun over terrain; it needs the skybox split out first.

**Phase 3 (render scale + overlay merge):**
- **Render scale is the largest remaining fill lever.** The Switch profile list was
  `{1080p, 720p}` while the shipped world height was 480p — a height matching no
  entry, so the panel reported "Normal HD" and selecting it would have *raised* the
  world to 720p. Now: profiles `{1080p, 720p, 853×480, 640×360}`, and the Switch
  default world height is **360** (clamp floor 360; the env var accepts any numeric
  height). UI/menus stay native.
- **Overlay pass merge (audit 02 W2):** the upscale/FXAA now draws into a dedicated
  `DONT_CARE`/`UNDEFINED` overlay pass and `endFrame` appends ImGui to the same
  pass, removing a native-resolution clear + a pass begin/end per in-world frame.
  The merge pass is separate from the `LOAD` overlay pass specifically so it is
  valid on a swapchain image whose layout is `UNDEFINED` (first frame after a
  mid-world rebuild).

Both audited (no blockers; the two MAJOR overlay-merge follow-ups — the initial
layout above and the volumetric-ordering guard — were fixed before deploy).
