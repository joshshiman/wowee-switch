# Audit 10 — Characters, NPCs and visual effects

Scope: the character/NPC renderer, appearance composition, unit portraits and raid
icons, spell visual effects, M2 particles & ribbons, footprints, quest markers,
swim/water effects, mount dust, weather, lightning, lens flare, and the
"combat tanks FPS" problem.

Hardware under audit: Tegra X1 gm20b, 4× Cortex-A57, Mesa NVK via libnx, ~25 GB/s
shared bandwidth, handheld 720p scene target (853×480 on Switch). The device is
**GPU fill/draw-count bound** (`docs/FINDINGS.md:718-740, 991-1007, 1067-1084`).

Method: static read of the character/effect renderers and their callers, plus the
per-frame UBO and shader that feed them. No console run. Every claim is anchored
to a file:line. Cost that depends on live scene state is filed under *measure
first*. Cross-refs: `docs/audit/04-m2-models.md` (M2 particles/ribbons, shared
buffer and budget machinery), `docs/audit/09-shaders-and-bandwidth.md`.

## Framing (what is already true on Switch)

- **Humanoid characters do NOT use the instanced/batched path.** Creatures, doodads
  and game objects go through `M2Renderer`, which already sorts opaque/transparent,
  batches and instances (`docs/audit/04-m2-models.md:29-31`). The player and every
  humanoid NPC go through `CharacterRenderer`, which draws **one instance at a
  time**, per batch, with per-instance vertex/index/bone binds
  (`character_renderer.cpp:2969-3066, 3107-3164`). "More actors" in combat means
  more *un-batched* draws on this path.
- **Render radius is already 90 on Switch** (`character_renderer.cpp:2877-2885`,
  run 64). Animation radius is **still 120** and is *not* ifdef'd
  (`character_renderer.cpp:2397`).
- **Each character owns its own double-buffered bone SSBO** of `MAX_BONES` (512)
  matrices = 32 KiB × 2 = **64 KiB/instance**, allocated unconditionally
  (`character_renderer.cpp:2785-2808`; `MAX_BONES` at `character_renderer.hpp:616`).
- **Local lights are capped to 8 on Switch**, so `character.frag.glsl`'s
  `localLightContribution` 64-light loop (`character.frag.glsl:170-187`) is already
  bounded (`switch_world_budget.hpp:34`, `renderer.cpp:616-623`).
- **Particle budget is already a frame budget** (6000 verts on Switch,
  `m2_renderer_particle_budget.hpp:31`), shared out with a distance cull and
  pressure feedback (`m2_renderer_render.cpp:680-739`). Ribbons have **no** distance
  cull (`m2_renderer_particles.cpp:460-542`; already filed as M2 in audit 04).
- **Run 60/63/64 attribution is the contract:** characters cost ≈ +60 ms across
  draw-count quartiles (`FINDINGS.md:991-1007`); indoors chars spike to 167-191
  draws vs ~25 outdoors (`FINDINGS.md:1067-1084`).

---

## Clear wins

### C1 — Shadows are sampled every character fragment even when nothing casts (HIGH)
`shadowParams.x` is written from `shadowsEnabled`, **not** from the caster scope:
`renderer.cpp:596-598`. But `shadowsEnabled` is hard-wired `true`
(`renderer.hpp:346`, `setShadowsEnabled` ignores its argument, `renderer.hpp:377`;
`setShadowQuality` only sets `shadowQuality_`, `renderer.hpp:390-392`). On Switch
shadow quality is forced to **0** at startup and in every setting sink
(`renderer.cpp:819-822, 839-847`), so no casters are drawn and the atlas is
clear-only (clear depth = 1.0, `renderer.cpp:1612-1614`). The character fragment
shader still runs the whole shadow path:

```glsl
// character.frag.glsl:410
if (shadowParams.x > 0.5) { shadow = outdoorShadow(FragPos, shadowNormal, ldir); }
```
`outdoorShadow` (`character.frag.glsl:145-168`) does up to **8 plane-corrected
`sampler2DShadow` taps** plus per-tap `shadowDepthGradient` matrix math
(`:91-126`) — every tap returning 1.0 against the cleared map. Pure discarded fill,
scaling with character screen coverage (worst in combat).

- **Fix:** write `shadowParams.x = (shadowsEnabled && shadowLevelDrawsCasters(shadowQuality_)) ? 1 : 0`
  (`shadowLevelDrawsCasters` already exists, `shadow_quality.hpp:48`, already used at
  `renderer.cpp:4722`). One line; the same UBO feeds `m2/terrain/wmo` frag shaders,
  so the whole scene benefits, not just characters.
- **Impact:** HIGH — removes 4-8 shadow taps + gradient math from every lit
  character fragment, the largest single fill lever in this domain.
- **Quality/risk:** LOW. Visually identical because the cleared atlas already
  evaluates to fully lit (verified: clear depth 1.0, all comparisons pass).
- **Quick win vs larger:** Quick — one assignment.
- **Switch-gate:** none needed; correct on every platform, but Switch is where it
  currently costs.

### C2 — Characters between animation radius 120 and draw radius 90 still compute bones (MED, quick)
`animUpdateRadius` defaults to **120** (`character_renderer.cpp:2397`), while the
Switch draw radius is **90** (`character_renderer.cpp:2882`). Characters in the
90-120 band have their bone matrices recomputed, their bone buffers uploaded
(`:3029-3030`) and their attachments solved every frame — and are then culled at
draw (`:2981`). `WOWEE_CHAR_ANIM_RADIUS` cannot be set on the console.

- **Impact:** MED — pure CPU + SSBO write bandwidth for invisible NPCs. Grows in
  dense hubs (run 63's inn). Not GPU fill, so it will not move FPS much, but it is
  free headroom and reduces contention with the render thread.
- **Fix:** on Switch clamp `animUpdateRadius = renderRadius` (or `min(90, ...)`).
- **Quality/risk:** LOW — a character at >90 is never drawn.
- **Quick win vs larger:** Quick.
- **Switch-gate:** `#ifdef WOWEE_SWITCH` on the default.

### C3 — Per-instance bone SSBOs are 64 KiB each, allocated for every instance unconditionally (MED, memory)
`prepareRender` allocates two `MAX_BONES×64 B` buffers per instance with **no
distance/frustum gate** (`character_renderer.cpp:2781-2808`). A typical character
model has 50-120 bones, so ~75 % of each 32 KiB slot is never addressed. ~150
character instances ≈ **9.6 MiB** of GPU memory, double-buffered, independent of
how many are on screen.

- **Impact:** MED on the memory ceiling (the structural risk, `AGENTS.md:282-287`);
  LOW on FPS. Contrast `M2Renderer`, which uses **one shared mega bone SSBO** with
  per-instance offsets (`m2_renderer_render.cpp:751-789`).
- **Fix (two levels):** (a) size the buffer to `model.bones.size()` at first use
  instead of `MAX_BONES`; (b) adopt the M2 mega-bone pattern and address bones via a
  dynamic offset on set 2 (or push-constant offset) — one buffer for all characters.
- **Quality/risk:** LOW (a) / MEDIUM (b).
- **Quick win vs larger:** (a) quick, (b) larger.
- **Switch-gate:** sizing/mega-buffer is platform-neutral.

### C4 — Opaque/transparent ordering is per-instance, not per-frame (MED, fill)
`render()` walks instances and, inside each, runs pass 0 (opaque) then pass 1
(transparent) (`character_renderer.cpp:3107-3164`; comment at `:3100-3102`
explains the intent). Because the two passes are nested *inside* the instance loop,
character N's blended hair/cape is recorded before character N+1's opaque body, so
transparent geometry is not depth-rejected by the opaque bodies drawn later, and
blend overdraw rises with crowd size — exactly the combat/hub case.

- **Impact:** MED fill (additive/blended character overdraw), grows with NPC count.
- **Fix:** hoist to a global two-phase: loop all instances emitting opaque batches,
  then loop again emitting transparent batches. The `pendingDraw` batching machinery
  (`:3048-3067`) carries over unchanged.
- **Quality/risk:** LOW-MED (draw order changes are visible only as fewer artifacts;
  sorting within transparency is still unsorted, same as today).
- **Quick win vs larger:** Medium.
- **Switch-gate:** none.

### C5 — `getWaterVegetationPositions` allocates a vector every frame, always (LOW-MED, quick)
`SwimEffects::update` calls `m2Renderer->getWaterVegetationPositions(camPos, 60.0f)`
**unconditionally** whenever an M2 renderer exists (`swim_effects.cpp:526-540`),
which is every frame in the world (`renderer.cpp:2346-2347`). The function builds
and **returns a `std::vector<glm::vec3>` by value** (`m2_renderer_particles.cpp:73-86`)
— a heap allocation and a full scan of `waterVegetationInstanceIndices_` per frame,
even on dry land or indoors.

- **Impact:** LOW-MED CPU/allocation churn on the frame path; relevant because the
  console heap is fragile (`FINDINGS.md:527-570`).
- **Fix:** gate the call on "character is in/near water" (`cc.isSwimming() ||
  wading`) and/or reuse a caller-owned scratch vector.
- **Quality/risk:** LOW.
- **Quick win vs larger:** Quick.
- **Switch-gate:** none.

### C6 — Active spell visuals have no global cap and no cooldown (MED, quick)
`playSpellVisual`/`playSpellVisualPrecast` push a new M2 instance per cast with no
budget (`spell_visual_system.cpp:341, 485, 503`). The only cap is on the Acherus
portal path (`spell_visual_system.cpp:711`, 128). In combat with multiple casters
each cast kit (and its mirror hand copy) becomes another M2 instance with particles
and ribbons. The particle system culls emitters by distance
(`m2_renderer_render.cpp:690-724`), so the draw side is bounded, but instance count
and simulation are not.

- **Impact:** MED in combat (draw count + particle fill), near-zero solo.
- **Fix:** a global concurrent-effect budget (e.g. 64) and/or a per-caster cooldown,
  dropping the oldest/least-relevant; mirror the particle emitter soft limit
  (`m2_renderer.hpp:1078`).
- **Quality/risk:** LOW-MED.
- **Quick win vs larger:** Quick.
- **Switch-gate:** a lower cap on Switch.

### C7 — Snow weather draws 8 px point sprites with no overdraw guard (LOW-MED)
Snow pushes `particleSize = 8.0f` (`weather.cpp:262`) and draws up to `MAX_PARTICLES
= 2000` points additively blended against the overlay pass (`weather.cpp:233-283`,
`weather.hpp:171`). At hand width that is large blended fill around the camera with
no depth-write and no per-particle screen-size clamp.

- **Impact:** LOW-MED, weather-dependent (a couple of zones). Combined with clouds
  now skipped, keep in mind for the rain/snow zones.
- **Fix:** cap size by distance, or reduce count on Switch (the density scale exists,
  `weather.cpp:156-158`).
- **Quality/risk:** LOW.
- **Quick win vs larger:** Quick.
- **Switch-gate:** lower `MAX_PARTICLES`/size on Switch.

### C8 — Lens flare is 8 screen-anchored additive quads, always enabled (LOW-MED, measure)
`lensFlare` defaults enabled (`lens_flare.hpp:106`) and draws **eight** additive
quads sized in screen space (main glow 0.3 of screen, halo 0.22, etc.;
`lens_flare.cpp:147-175, 291-318`) whenever the sun is on screen in daylight. Their
fill scales with screen area, matching the reported "sky views are slowest" shape
(`FINDINGS.md:1026-1030`) alongside the already-exonerated clouds.

- **Impact:** LOW-MED, view-dependent (worst when the sun is framed).
- **Fix:** measure with lens flare disabled looking at the sun; if it matters, cap
  the element count/size on Switch. The `#ifdef WOWEE_SWITCH` skips landing in the
  sky block recently make this an easy A/B.
- **Quality/risk:** LOW.
- **Quick win vs larger:** Quick after measurement.
- **Switch-gate:** `#ifdef WOWEE_SWITCH` on `setEnabled(false)` or a size cap.

### C14 — Footprints and quest markers issue one draw per item (LOW, quick)
`FootprintRenderer::render` emits `vkCmdDraw(cmd, 6, 1, …)` plus a descriptor bind
and push constant **per print** (`footprint_renderer.cpp:345-377`), up to `kMaxPrints
= 72` (`:32`), culled at 100 units (`:347`). All prints use only 6 textures
(`kTextureCount`, `footprint_renderer.hpp:68`), so they could be grouped into ≤6
instanced draws. `QuestMarkerRenderer::render` is the same shape — one draw + bind +
push per marker outside a 115-unit cull (`quest_marker_renderer.cpp:390-455`), with
only 3 textures (`:440`).

- **Impact:** LOW per system, but up to ~72 footprint draws in a walked-through hub;
  cheap draw count to reclaim.
- **Fix:** batch by `textureIndex`, instance the quads (or build one dynamic vertex
  buffer per texture and one draw each).
- **Quality/risk:** LOW.
- **Quick win vs larger:** Quick.
- **Switch-gate:** none.

---

## Measure first

### C9 — Portrait / preview offscreen passes (MED, needs a count)
Up to eight face portraits (npc, questnpc, target, pet, focus, party1-4;
`application.cpp:5266-5279`) plus the paperdoll/dressup/pet models each own a
`CharacterPreview` with its own `CharacterRenderer` and are composited when a
visible frame asks (`renderer.cpp:4969-4976`). Face step is 10 Hz, model step 20 Hz
(`unit_portrait.cpp:58-71`). Each composite is a full offscreen render pass +
character draw. At ~10 FPS that can be several offscreen passes per frame. FINDINGS
judges caching not worth it (`FINDINGS.md:757-763`), so treat the *number of due
passes per frame* as the lever: cap to N composites/frame or 5 Hz face step when
frame time is high.

- **Impact:** MED IF the offscreen pass count is material at portrait size; unknown
  without a counter.
- **Fix / how to measure:** log composites-per-frame and their GPU share; only then
  decide. A budget of "at most 2 offscreen previews per frame" is a cheap try.
- **Quality/risk:** LOW (portraits are small, but they are visible UI).
- **Switch-gate:** reduce portrait resolution / step on Switch.

### C10 — Character draw is per-instance, un-batched, un-instanced (MED-HIGH, larger)
`CharacterRenderer::render` binds vertex/index/bone per instance and
material descriptor per batch (`character_renderer.cpp:2969-3066`). Shared NPC
displays (`displayIdModelCache_`, `entity_spawner.cpp:247-334`) reuse models, so
instancing same-model instances into one `vkCmdDrawIndexedInstanced` per batch is
feasible, dropping hundreds of draws to dozens. This is CPU/command cost, and the
device is currently GPU-bound with CPU passes summing ~10-25 ms
(`FINDINGS.md:721-726`), so it will **not** move FPS today — but it removes the
per-draw overhead that will dominate if a future fill fix makes CPU the limit.

- **Impact:** MED-HIGH if any fill reduction shifts the bottleneck to CPU; LOW now.
- **Fix:** instance the opaque batches of same-model NPCs (bones per instance via
  the shared SSBO from C3b), keeping the per-instance material path for overrides.
- **Quality/risk:** MEDIUM-HIGH (skin overrides, geosets, per-instance texture
  slots all resist naive instancing).
- **Quick win vs larger:** Larger.
- **Switch-gate:** none.

### C11 — Character LOD / impostor for distant NPCs (MED-HIGH, larger)
There is no mesh LOD for characters (same LOD situation as M2, audit 04 M4) and no
NPC impostor. Characters draw full mesh out to 90 units. Given run 64 already cut
90 and indoor char draws are the spike (`FINDINGS.md:1099-1102`), a distance-based
vertex/AO impostor or a hard per-frame character-draw budget is the only remaining
geometry-side lever.

- **Impact:** MED-HIGH (draw + fill at 60-90 units).
- **Quality/risk:** HIGH (faces are the most scrutinized pixels).
- **Quick win vs larger:** Larger.

### C12 — Ribbons have no distance cull (MED, quick — cross-ref)
`renderM2Ribbons` walks every `ribbonInstanceIndices_` instance with no distance
test and issues one draw per emitter (`m2_renderer_particles.cpp:460-542, 584-596`),
unlike the particle path. Spell-heavy frames pay it. Already filed as audit 04 M2;
restated here because ribbons are the combat VFX case. Quick fix: reuse
`emitterCullDistSq`/`cachedMaxRenderDistSq_`.

### C13 — Particle emitter re-sort every frame (LOW — cross-ref)
`std::stable_sort(particleInstanceIndices_…)` with a per-comparison distance
(`m2_renderer_render.cpp:705-706`), every frame. Filed as audit 04 M8. Sort only
when the protected set or the 80-unit membership changes.

---

## Ranked shortlist

| # | Item | Impact | Risk | Effort | Evidence |
|---|------|--------|------|--------|----------|
| 1 | **C1** Skip shadow sampling when no casters (shadowParams.x from caster scope) | HIGH (fill) | LOW | one line | `character.frag.glsl:410,145-168`; `renderer.hpp:346,377,390`; `renderer.cpp:596-598,819-822` |
| 2 | **C2** Match anim radius (120) to draw radius (90) on Switch | MED (CPU/bw) | LOW | small | `character_renderer.cpp:2397,2882` |
| 3 | **C4** Global opaque-before-transparent two-phase draw | MED (fill) | LOW-MED | medium | `character_renderer.cpp:3107-3164` |
| 4 | **C3** Right-size / share bone SSBOs | MED (memory) | LOW-MED | two levels | `character_renderer.cpp:2785-2808`; `m2_renderer_render.cpp:751-789` |
| 5 | **C6** Cap concurrent spell visuals | MED (combat draws) | LOW-MED | small | `spell_visual_system.cpp:341,485,711` |
| 6 | **C5** Gate/alloc-free `getWaterVegetationPositions` | LOW-MED (alloc) | LOW | quick | `swim_effects.cpp:526-540`; `m2_renderer_particles.cpp:73-86` |
| 7 | **C12** Distance-cull ribbons | MED (VFX draws) | LOW | quick | `m2_renderer_particles.cpp:460-542` |
| 8 | **C14** Batch footprint/quest-marker draws | LOW | LOW | quick | `footprint_renderer.cpp:345-377`; `quest_marker_renderer.cpp:390-455` |
| 9 | **C7** Weather point overdraw | LOW-MED | LOW | quick | `weather.cpp:262,283` |
| 10 | **C8** Lens flare 8 additive quads (measure) | LOW-MED (fill) | LOW | measure→quick | `lens_flare.cpp:147-175,291-318` |
| 11 | **C9** Portrait offscreen pass budget (measure) | MED? | LOW | measure→medium | `renderer.cpp:4969-4976`; `unit_portrait.cpp:58-71` |
| 12 | **C10** Instance same-model NPC characters | MED-HIGH? | HIGH | larger | `character_renderer.cpp:2969-3066` |
| 13 | **C11** Character LOD/impostor at 60-90 u | MED-HIGH | HIGH | larger | `character_renderer.cpp:2877-2885` |
| 14 | **C13** Stop per-frame emitter sort | LOW | LOW | quick | `m2_renderer_render.cpp:705-706` |

### The "combat tanks FPS" story, end to end
Combat adds nearby hostile actors (C2's close-range `boneInterval = 1`,
`character_renderer.cpp:2499-2503`), their cast kits as extra M2 instances (C6),
and particle/ribbon fill (already budgeted; ribbons unculled, C12). Because those
actors fill the screen, the discarded shadow taps of **C1** scale up exactly in
combat, and blended character overdraw (**C4**) does too. C1 is the single change
most likely to move the combat number; C2 and C6 are the cheapest supporting cuts.

### Notes on what is already right (do not re-open)
- Particle frame budget + distance cull + pressure feedback (`m2_renderer_render.cpp:680-739`,
  `m2_renderer_particle_budget.hpp`).
- `boneUploadState` skips re-uploading unchanged poses (`bone_upload_state.hpp:20-26`;
  used at `character_renderer.cpp:3029`).
- Distance bone throttling `boneInterval` 2/4 past 45/90 u (`character_renderer.cpp:2499-2503`).
- Batch order and per-batch static facts cached at load (`character_renderer.hpp:287-313`).
- No per-frame heap allocation in the normal character/batch draw path (scratch is
  reused: `toUpdate_`, `animFutures_`, `reclaim*Scratch_`).
- Portraits are change-guarded and throttled to 10/20 Hz (`unit_portrait.cpp:58-100`).
- Local lights capped to 8 on Switch (`switch_world_budget.hpp:34`).
