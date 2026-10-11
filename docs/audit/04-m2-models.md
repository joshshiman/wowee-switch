# Audit 04 — M2 (doodad/creature model) rendering

Scope: M2 draw batching/instancing, bone/skinning SSBOs, particles & ribbons, model
culling, LOD, view distance, the skybox M2 renderer, and per-M2 GPU cost on the
Switch (Tegra X1 gm20b, 4× Cortex-A57, ~25 GB/s shared, NVK/Mesa via libnx,
handheld 720p scene target 853×480).

Method: static read of the M2 renderer and its callers. No console run. Every
claim is anchored to a line; costs that depend on live scene state are filed under
*measure first*. Cross-refs: `docs/audit/09-shaders-and-bandwidth.md` (fill/overdraw,
local-light loop), AGENTS.md traps.

## Framing (what is already true on Switch)

- **GPU cull is compiled out on Switch.** `gpuCullAvailable = false`
  (`m2_renderer_render.cpp:1083-1088`) and `dispatchCullCompute` is never recorded
  (`renderer.cpp:1538-1550`). Visibility is CPU-side every frame — a placement-cluster
  broad phase (`m2_renderer_render.cpp:1285-1301`, `m2_visibility_clusters.hpp`) then
  a per-instance distance/frustum predicate (`m2_renderer_render.cpp:1197-1268`).
- **Distance is already short.** `kDefaultViewDistance = 420` (`switch_world_budget.hpp:8`),
  M2 scaled ×0.45 (`renderer.cpp:4313`) → **`viewDistanceAbsolute_ ≈ 189` units**
  (`m2_renderer.hpp:593-609`). `environmentDetail_ = 1.0` default
  (`m2_renderer.hpp:1111`), so `smoothedRenderDist_ ≈ 189` (`m2_renderer_render.cpp:1141`).
- **Everything is clamped to that 189.** `m2InstanceMaxDistSq` applies every widening
  factor *then* clamps to `viewDistanceAbsolute²` (`m2_view_distance.hpp:42`). So the
  per-instance widening — big-model factor, `disableAnimation ×2.6`
  (`m2_renderer.cpp:93-96`), game-object floor 600 (`render_constants.hpp:45`) — is
  **neutralized on Switch**: trees and mailboxes draw at the same 189 as a pebble.
- **Opaque is already batched + instanced.** Sorted by `modelId`, sub-grouped by LOD,
  one `vkCmdDrawIndexed(_, groupSize, …)` per (model, LOD, batch)
  (`m2_renderer_render.cpp:1381, 1913`). This is the good path.
- **Run 60 attribution is the contract:** M2 draws +122 ms (135→257); draw-count
  tracks frame time. So the lever with evidence is **per-draw GPU cost and fill**, not
  vertex fetch per se (`docs/FINDINGS.md:991-1007`).

---

## Clear wins

### M1 — The skybox M2 renders through the full M2 path, every frame (HIGH)
`skyboxModelRenderer_` is a second, full `M2Renderer` in `skyMode_`
(`renderer.cpp:3904-3912`) that is `prepareRender`+`render`ed *inside* the sky block
(`renderer.cpp:2328-2330`, `3443-3444`). Its one model — `hellfireskybox.m2` — carries
**34 render batches / 23 textures / 5 transparency tracks / 7 UV anims / 6 global
sequences**, drawn as 6 opaque + 10 alpha + 18 additive layers
(`m2_renderer_render.cpp:1354-1372` comment). Eighteen additive layers cover the whole
dome → whole screen at the far plane, on a **fill-bound** device, *and* a procedural
gradient `Skybox::render` already draws a sky (`skybox.cpp:124-154`). Run 62 already
identified the sky as the worst view (`docs/FINDINGS.md:1026-1040`) and shipped a
cloud-only diagnostic.

- **Impact:** HIGH. This is the one place where a single "model" costs tens of draws
  **and** several full-screen overdraw passes per frame. Removing it is the single
  largest M2 win available.
- **Quality/risk:** MEDIUM. Losing the authored nebula/cloud layers changes the sky.
  The tree already has the switch (`WOWEE_NO_SKY_M2`, `renderer.cpp:1996`) so this can
  be A/B'd before any default changes.
- **Quick win vs larger:** Quick — default the sky M2 off on Switch, or keep only its
  opaque base and route the rest to the procedural sky. Larger — bake the sky model to
  a cubemap once per zone and sample it.
- **Switch-gate:** `#ifdef WOWEE_SWITCH` around the `useOriginalSkybox` M2 branch, or
  a `skyMode_` layer cap in the renderer. No shader variant needed.

### M2 — Ribbons have no distance cull; particles do (MED, quick)
`renderM2Ribbons` walks **every** `ribbonInstanceIndices_` instance and emits strips
(`m2_renderer_particles.cpp:460-542`) with no distance test — unlike the particle loop,
which uses `emitterCullDistSq` (`m2_renderer_render.cpp:690-724`). Ribbons are called
unconditionally each frame (`renderer.cpp:3496`) and produce one draw per emitter per
instance (`m2_renderer_particles.cpp:584-596`). On a busy/spell-heavy frame this is
untouched draw count and vertex writes.

- **Impact:** MED (grows with spell/portal density; near-zero in calm field).
- **Quality/risk:** LOW. Gate on `instance.cachedCullCenter` distance to camera.
- **Quick win vs larger:** Quick win — reuse `cachedMaxRenderDistSq_` (or the particle
  cull) as the ribbon cutoff.
- **Switch-gate:** ordinary C++ predicate, no shader.

### M3 — Dead GPU-cull resources still allocated on Switch (MED, quick)
The entire cull block — compute pipelines, HiZ pipeline, descriptor pool, and
`MAX_CULL_INSTANCES = 24576` input/output SSBOs (`m2_renderer.hpp:784`) — is created
unconditionally (`m2_renderer.cpp:760-920`: input `24576×32B`≈768 KiB ×2 + output
`24576×4B`×2 + uniforms). On Switch none of it is ever dispatched.

- **Impact:** MED on the memory ceiling (≈1.6 MiB/buffer-set ×2 renderers with the
  skybox M2), LOW on FPS; still frees headroom the driver keeps refusing at the
  allocation edge (AGENTS.md "console memory is the structural risk").
- **Quality/risk:** LOW.
- **Quick win vs larger:** Quick win — wrap the whole cull init/destroy in
  `#ifndef WOWEE_SWITCH`.
- **Switch-gate:** `#ifndef WOWEE_SWITCH`.

### M4 — Geometric LOD is inert for WotLK models (HIGH leverage, larger)
`m2SkinSectionLod` returns **0** for model version ≥ 264 and the code only loads
`skin00` (`m2_skin_lod.hpp:8-12`), applied at `m2_renderer.cpp:1957`. So
`availableLODs` is always `1<<0` for every shipped 3.3.5a M2
(`m2_renderer.cpp:2356-2360`). The LOD distance tiers (40/80/150 yards,
`m2_renderer_render.cpp:1604-1609`, `1983-1988`) and `M2_LOD3_DISTANCE`
(`render_constants.hpp:20`) select the *same* full-detail mesh at every distance —
only the **bone update** is skipped past 150 (`m2_renderer_render.cpp:579-582`). This
is why distance/LOD tuning has moved the needle so little: there is no cheaper mesh to
select.

- **Impact:** HIGH *if* per-vertex/per-fragment work on doodads is a meaningful share
  (needs the fill split; see measure-first). It is the only way distance can cut doodad
  geometry cost.
- **Quality/risk:** MEDIUM-HIGH. Requires loading `skin01/skin02` and repointing the
  batch index ranges per LOD — real LOD plumbing.
- **Quick win vs larger:** Larger.
- **Switch-gate:** independent of Switch; benefits both trees, gated by distance.

### M5 — No impostor/billboard fallback for small distant doodads (HIGH, larger)
The only billboard path is *emissive* glow sprites (`m2_renderer_render.cpp:1697-1809,
2162-2193`). Trees, bushes and props draw their **full mesh** out to the 189-unit
boundary. Run 60/61 attribute the horizon cost to M2 overdraw+draws, and the only
mesh-reduction lever (M4) is inert. A tree impostor at distance is the classic fix.

- **Impact:** HIGH (fill + draw count at the horizon — the exact reported worst case).
- **Quality/risk:** HIGH. Needs per-model impostor generation and correct alpha.
- **Quick win vs larger:** Larger.
- **Switch-gate:** distance-gated; can ship desktop-off, Switch-on.

---

## Clear wins (cheap) / measure first

### M6 — Vertex format wastes 24 B/vertex on bone data (MED-HIGH)
Stride is **72 B** with bone weights *and* indices stored as `R32G32B32A32_SFLOAT`
(16 B each) while the source is `uint8_t[4]` (`m2_renderer.cpp:297-321`, source
struct `m2_loader.hpp:105-111`). Packing to `R8G8B8A8_UNORM`/`_UINT` gives **48 B**
(`R8G8B8A8`), a **33 % cut in animated-vertex fetch** — the exact class of model that
skins. Requires matching changes in the main pipeline, the shadow pipeline and the
instanced-shadow pipeline (all share the binding).

- **Impact:** MED-HIGH for skinned models; LOW if the scene is draw/fill bound rather
  than vertex bound (measure).
- **Quality/risk:** LOW-MED (shader reads `aBoneIndicesF` as `vec4` — must convert,
  `m2.vert.glsl:79`; `_UINT` avoids the unorm rounding concern).
- **Quick win vs larger:** Medium — several pipeline builders + uploader.
- **Switch-gate:** none needed.

### M7 — Instance SSBO is 112 B with dead padding; Switch default capacity is huge (MED)
`M2InstanceGPU` is 112 B, including an unused `int32_t _pad[2]` and a 16 B `uvLinear`
that only texture-anim batches use (`m2_renderer.hpp:737-746`). It is written per
visible instance every frame (`m2_renderer_render.cpp:1627-1641`, `1840-1863`,
`2082-2097`). `MAX_INSTANCE_DATA = 32768` is **unconditional** (no `#ifdef`,
`m2_renderer.hpp:753`) and is the *initial* allocation
(`m2_renderer.cpp:708`, `defaultInstCap`), i.e. **3.67 MiB × 2 ≈ 7.3 MiB resident**
before any growth. AGENTS.md still records the Switch figure as 4096 — the code no
longer matches.

- **Impact:** MED. Bandwidth is small per frame; the resident memory is the real win,
  and it feeds the allocation-edge failures.
- **Quality/risk:** LOW.
- **Quick win vs larger:** Quick win — start Switch capacity small (grow on demand,
  the growth path already exists: `ensureInstanceCapacity`, `m2_renderer_render.cpp:976`).
- **Switch-gate:** `#ifdef WOWEE_SWITCH` default capacity; struct slimming is global.

### M8 — Particle emitter list is re-sorted every frame (LOW)
`std::stable_sort(particleInstanceIndices_…)` with a lambda that recomputes
distance per comparison (`m2_renderer_render.cpp:705-706`) runs each frame over every
emitter instance. The priority only changes when an instance crosses an 80-unit
sphere or the set changes.

- **Impact:** LOW-MED CPU (grows with emitter count, which cities maximise).
- **Quality/risk:** LOW.
- **Quick win vs larger:** Quick win — sort only when the protected set changes, or
  partition instead of sort.
- **Switch-gate:** none.

### M9 — Two full per-instance CPU passes per frame (MED, measure)
`update()` walks `animatedInstanceIndices_` computing distance+frustum, then
`prepareRender` walks it again for the mega-bone upload
(`m2_renderer_render.cpp:491-594`, `747-790`), and `render()` walks all `instances`
a third time (`m2_renderer_render.cpp:1197-1268`). Cluster broad phase helps, but
the accepted clusters still run the per-instance predicate. `lastVisibilityTestCount_`
/ `lastClusterSkippedCount_` (`m2_renderer.hpp:556-557`) already measure this.

- **Impact:** MED *if* instance count is large (ground clutter) — read
  `WORLD_PERF m2Instances` + the visibility counters before acting.
- **Quality/risk:** LOW.
- **Switch-gate:** none.

### M10 — `environmentDetail_` / ground-detail cap are unused on Switch (MED, quality tradeoff)
`environmentDetail_` defaults to 1.0 and `groundDetailMaxDistance_` to 0 (no cap)
(`m2_renderer.hpp:1111-1112`); both are only reachable from a Lua CVar
(`application.cpp:514-525`). Since the ×0.45 scale is already applied, lowering
`environmentDetail_` on Switch (e.g. 0.7 → M2 distance ≈132) is the cleanest single
distance knob still available. Ground-clutter density is already cut
(`graphics_defaults.hpp:23`, 15 %), but the **M2 ground-detail distance** is not.

- **Impact:** MED — directly scales doodad draw count and overdraw.
- **Quality/risk:** MED — visible pop-in (fog already tracks 0.95× full distance).
- **Switch-gate:** set the default in the Switch branch.

---

## Ranked shortlist

| # | Recommendation | Impact | Risk | Effort | Gate |
|---|---|---|---|---|---|
| 1 | Default sky M2 (34 batches, 18 full-screen additive) off / bake to cubemap (M1) | HIGH | MED | Quick→L | `WOWEE_SWITCH` |
| 2 | Distance-cull ribbons like particles (M2) | MED | LOW | Quick | predicate |
| 3 | Don't allocate dead GPU-cull SSBOs/pipelines on Switch (M3) | MED (mem) | LOW | Quick | `#ifndef WOWEE_SWITCH` |
| 4 | Load `skin01/skin02` for real distance LOD (M4) | HIGH | MED-HIGH | Large | distance |
| 5 | Impostor/billboard for small distant doodads (M5) | HIGH | HIGH | Large | distance |
| 6 | Pack bone weights/indices to `R8G8B8A8` (M6) | MED-HIGH | LOW-MED | Med | none |
| 7 | Slim instance SSBO + small Switch default capacity (M7) | MED | LOW | Quick | `WOWEE_SWITCH` |
| 8 | Lower `environmentDetail_` default on Switch (M10) | MED | MED | Quick | `WOWEE_SWITCH` |
| 9 | Throttle particle emitter sort (M8) | LOW-MED | LOW | Quick | none |
| 10 | Merge the per-instance CPU passes (M9) | MED | LOW | Med | none |

## Measure first

- **Sky M2 share.** Turn on `WOWEE_NO_SKY_M2` (or read `skyM2 draws:` /
  `skyDiagDrawsOpaque_/Transparent_`, `m2_renderer_render.cpp:2205-2212`) and
  `skyDiagDraws*` against `WORLD_PERF` M2 draws to size M1 before changing a default.
- **Is the M2 scene draw- or fill-bound at 189 units?** `gpuMark(currentCmd, "m2")`
  (`renderer.cpp:3497`) still wraps both the sky and the world M2 draws. Split the
  timer to separate the skybox M2 from the world M2 to attribute M1 vs M4/M5.
- **Instance SSBO bandwidth** (M6/M7): compare `WORLD_PERF` frame time with
  `WOWEE_M2_NO_SKINNING` off/on and a smaller `MAX_INSTANCE_DATA`; the 72→48 B change
  only pays if vertex fetch is on the critical path.
- **CPU cull cost** (M9): read `lastVisibilityTestCount_` / `lastClusterSkippedCount_`
  and `m2Instances` from `boot.log`; if `lastClusterSkippedCount_` is small the
  cluster broad phase is not earning its keep at 189 units.
- **Ground-detail M2 population** (M10): count `cachedIsGroundDetail` instances and
  their contribution to `m2Draws` before cutting distance.
