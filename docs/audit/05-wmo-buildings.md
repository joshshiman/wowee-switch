# Audit 05 — WMO (buildings / world model objects)

Scope: WMO portal/room culling, group/batch batching, material sets & descriptor
churn, lighting, occlusion, distance/LOD, and the **interior is slower than
outdoors** problem. Read-only; observations from `perf/switch-audit`.

## How the path runs (facts verified in code)

- WMO recording runs on a worker thread into a secondary command buffer
  (`renderer.cpp:3243-3253`), after terrain and sky. Main thread does
  `prepareRender()` (`renderer.cpp:3209`).
- Per instance, `cullInstance` (`wmo_renderer.cpp:1968-2057`) applies, in order:
  frustum→portal→distance. On Switch the distance test runs **unconditionally**
  (the `#ifndef WOWEE_SWITCH` at `wmo_renderer.cpp:2040-2044` removes the
  `cullingEnabled_` gate), using `groupViewDistance = viewDistance_`.
- `viewDistance_` for WMO is the world distance × 0.6 (`renderer.cpp:4312`);
  default world distance on Switch is 420 (`switch_world_budget.hpp:8`), so the
  WMO horizon is ~252 units.
- Portal culling is now on by default on Switch (`wmo_renderer.cpp:310-312`,
  `cullingEnabled_` default `false` at `wmo_renderer.hpp:947`), and only runs
  when the model actually has portals (`wmo_renderer.cpp:1994`).
- Draw loop (`wmo_renderer.cpp:2085-2232`) iterates `dl.visibleGroups` in
  **group index order**, then each group's `mergedBatches`, coalescing only
  exactly-adjacent triangle ranges (`appendOrderedTriangleRange`,
  `ordered_triangle_range.hpp`). One `vkCmdDrawIndexed` per surviving range run.
- Material descriptor sets/UBOs are owned **per model** (`ModelData` is shared by
  all instances of a `modelId`), so they are not duplicated per instance.

## Clear wins (mechanical, low risk, do without a console run)

### W1 — `gatherLavaLights` allocates and scans every frame — LOW
`gatherLavaLights` builds a fresh `std::vector<Candidate>` with no reserve every
frame (`wmo_renderer.cpp:4472`) and scans **every instance × group × lavaLights**
(`4473-4488`), then `partial_sort`s (`4493`). Called unconditionally each frame
from `renderer.cpp:604-609`. Switch gate: none, runs on all builds.
Fix: keep a member/`thread_local` scratch vector with `reserve`, and early-out
when there are no lava groups. Pure win, no visual change.

### W2 — Local-light loop shades every WMO fragment, including baked interior — MEDIUM
`wmo.frag.glsl:170-188` loops `min(localLightMeta.x,64)` lights per fragment;
on Switch it is capped to the nearest 8 (`switch_world_budget.hpp:34`,
`renderer.cpp:616-622`). It is added for any non-window, non-lava fragment
**including interior MOCV-lit groups** (`wmo.frag.glsl:415-416`), which already
carry baked `MOCV` interior lighting. Interiors are fill-bound (walls fill the
frame), so this is close to worst-case fill.
Fix: skip `localLightContribution` when the group is interior-lit, or select a
smaller interior cap. Quality risk: interiors lose the warm torch/forge accent
on walls — gate behind a CVar and compare a screenshot.

### W3 — Opaque WMO groups are not distance-sorted (overdraw) — MEDIUM
`wmo_renderer.cpp:2127` walks `visibleGroups` in authored index order, so no
front-to-back submission and early-Z rejects little. Run 49/60 agree the frame
is GPU-fill bound and draw-count sensitive. Interiors (enclosed, overlapping
walls/ceilings + exterior shell) are the worst case.
Fix: sort the **opaque** subset of `visibleGroups` nearest-first (centre of
`worldGroupBounds[gi]` vs `camPos`); keep transparent/glass back-to-front and
after opaque. Medium work (ordering key + stable partition by pipeline),
medium risk (transparency ordering). Bigger than W1/W2.

### W4 — Batch key over-splits into extra draws/UBOs — LOW/MEDIUM
The batch key includes `specular`, `unfogged`, `emissiveLevel`, `isWindow`,
`isLava` on top of texture/blend/alpha/unlit (`wmo_renderer.cpp:927-931`), so
the same texture with a differing minor flag becomes a second `MergedBatch` →
second UBO/set/draw. `emissive`/`isWindow`/`isLava` are per-scan-name and rarely
mixed, but `unfogged`/`specular` can split otherwise identical walls. Every extra
batch also consumes a `MAX_MATERIAL_SETS` slot (`wmo_renderer.hpp:871-880`,
8192 on Switch — Elwynn already pressed this once).
Fix: fold flags that do not change the pipeline into per-draw push data, or
merge keys. Measure merged-batch count before/after (`debugDumpGroupsAtPosition`
already logs `batches=` per group at `wmo_renderer.cpp:4026`).

### W5 — Dead config / dead code — LOW (cleanup only)
`isGroupVisible` (`wmo_renderer.cpp:2736`) is never called; it also rebuilds a
frustum per call. `numCullThreads_` is set from env (`wmo_renderer.cpp:296`) but
culling is sequential (`2065`); the header still advertises parallel culling.
No perf effect, but they mislead the next reader.

## Measure first (plausible but unverified / may change visuals)

### M1 — Portal culling is weak; may not have helped inns at all — HIGH if it works
Five separate escape hatches make portal traversal ≈ frustum for most WMOs:
- camera outside all groups → show all (`wmo_renderer.cpp:2839-2846`);
- containing group not indoor-only → show all (`2851-2860`);
- containing group has no portal refs → show all (`2882-2890`);
- **every exterior group is unconditionally visible AND enqueued as a BFS
  seed** (`2898-2902`, `2924-2926`);
- models with no portals skip portal culling entirely (`1994`).
`isPortalVisible` tests only the portal AABB against the camera frustum
(`2783-2824`) — no portal back-face rejection and **no frustum clipping through
the portal**. So a room seen through a doorway draws in full, and a room behind a
wall whose portal AABB is in the frustum still opens.
Hypothesis for run 63's "indoors draws more": inside a building inside a city
WMO, the walk seeds from **every street group**, so every interior reachable
through any in-frustum exterior portal is drawn. Run 63 enabled the switch and
predicted "indoor wmoDraws collapse"; **FINDINGS has no post-63 indoor WMO count**
— this is unverified.
Plan: add an indoor `wmoDraws` + `portalCulled` + `distanceCulled` line and
re-run one 10 s inn sample. If draws did not drop, implement proper portal
frustum clipping (clip the view frustum through each portal polygon, reject
back-facing portals, and stop seeding the whole exterior set when the camera is
in an interior-only group). Larger, but this is the intended mechanism for the
interior problem. Risk: the exterior-seed rule exists because narrowing it once
hid Ironforge — change it only with a handheld pass in a city + a dungeon.

### M2 — Tighten interior view distance — MEDIUM, cheap
`cameraIndoors_` is already computed every frame (`renderer.cpp:2233`). Interiors
have a tiny visible horizon, so a smaller `groupViewDistance` when indoors (only
for interior-only groups) should drop `lastDistanceCulledGroups` with almost no
visual cost. Today the WMO horizon is ~252 everywhere (`renderer.cpp:4312`).
Risk: a window/doorway view loses distant exterior detail — clamp conservatively
and fog already hides pop (`renderer.cpp:569`).

### M3 — Merge groups/rooms into fewer buffers — MEDIUM/LOW, larger
Each group owns its own VB/IB (`wmo_renderer.hpp:517-519`) and is bound
per-group (`wmo_renderer.cpp:2157-2163`), so draws cannot coalesce across groups.
Concatenating a model's opaque group geometry into one buffer per model (with
per-instance base offset via push constant) would collapse binds and enable
multi-draw of adjacent ranges. Moderate work, medium risk (index type is
UINT16/group, offsets must be rebuilt), and NVK multi-draw perf is unmeasured on
Tegra — treat as measure-first.

### M4 — Precompute per-instance portal world AABBs — LOW
`isPortalVisible` transforms 8 corners **per portal ref, per instance, per frame**
(`wmo_renderer.cpp:2808-2820`). Portal geometry is static and instance matrices
are static except transports, so the world AABB can be cached on the instance.
Small CPU win (the WMO record path is single-threaded on a worker); low risk.

### M5 — LOD shells never engage on small interiors — LOW
`isLOD` requires `isLargeWmo = model.nGroups > 50` (`wmo_renderer.cpp:775`,
`791-796`), so inns/building WMOs never get distance-LOD. A distance band for
interior-only groups could drop whole room groups outdoors-facing. Low value for
the interior problem (interiors are near); park unless M1 lands.

## Explicitly NOT a WMO cost on Switch

- **WMO shadow pass is free.** Switch forces `shadowQuality = 0`
  (`renderer.cpp:819`) → `shadowLevelDrawsCasters(0) == false`
  (`shadow_quality.hpp:48`) → `wmoRenderer->renderShadow` is never called
  (`renderer.cpp:4722-4723`, `4864`). Do not "optimize" the shadow path.
- **Per-frame range-cull log is free.** `LOG_INFO` evaluates no arguments when
  INFO is disabled (`core/logger.hpp:135-140`), and Release pins WARNING.
- **Material descriptor churn is bounded.** Sets are per model, shared across
  instances; identity-deduped on bind (`wmo_renderer.cpp:2198-2202`). The risk is
  only pool *exhaustion* from too many batches (see W4).

## Ranked shortlist

1. **W1** lava-light scratch (do now — zero risk, removes a per-frame alloc).
2. **M1-measure**: instrument indoor `wmoDraws/portalCulled/distanceCulled` and
   take one inn sample; this decides whether the interior fix is portal
   clipping or something else. (Blocks everything below it.)
3. **M2** indoor view-distance tightening (reuses `cameraIndoors_`, cheap).
4. **W2** skip local lights on baked-interior fragments (CVar-gated).
5. **W4** de-split the material batch key; watch `MAX_MATERIAL_SETS` pressure.
6. **W3** front-to-back opaque ordering (fill/overdraw; interior-heavy).
7. **M1-implement** proper portal frustum clipping + back-face reject.
8. **M4** cached portal world AABBs.
9. **M3 / M5** group-buffer merging, interior LOD — larger, unclear payoff.
10. **W5** delete dead `isGroupVisible` / `numCullThreads_`.
