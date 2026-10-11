# Audit 09 — Shaders and Memory Bandwidth

Scope: fragment-shader complexity, overdraw, lighting math, sky/cloud/water/terrain/
post-process shaders, vertex formats, and layout-induced bandwidth waste on the
Switch (Tegra X1 gm20b, 4× Cortex-A57, ~25 GB/s shared, NVK/Mesa).

Method: read the shipped GLSL and the C++ that feeds it. This is a static audit —
no console run. Every claim is anchored to a line; where a cost can only be
confirmed on hardware it is filed under *measure first*.

## Framing

- The port is **fill-bound**, not CPU/geometry-bound: run 56 measured scene fill at
  ~238 ms with shadows/volumetric/bloom all at 0; run 60 showed the cost tracks
  *draw count*, run 61 nailed it to M2/WMO draws, run 62 showed sky views and
  interiors are the worst. So the levers that matter here are **per-pixel work and
  overdraw at the render resolution**, not vertex fetch.
- The world renders into an off-screen target at **853×480** (`switch_scene_extent.hpp:29`,
  `return 480`), ≈ **409 k fragments**. Everything below is priced against that:
  one extra full-screen texture tap ≈ 0.4 M texel reads; one extra full-screen
  pass ≈ 1.6 MB colour read + write.
- **Shaders are not compiled at runtime and there is no GLSL preprocessor on
  Switch.** The `.spv` are committed; the only build step is
  `wowee/tools/switch/verify_shaders.py`, which hashes the `.glsl`/`.spv` pair
  against `lighting_manifest.json` and rejects a stale pair. Consequently a
  "Switch shader variant" is **not** `#ifdef WOWEE_SWITCH` inside a `.glsl` — it is
  a second source+SPIR-V pair (e.g. `clouds_switch.frag.{glsl,spv}`) *selected in
  the C++ pipeline builder*, or a **Vulkan specialization constant** where the
  difference is a loop bound / branch. Every "Switch-gate" note below is written
  that way. The existing pattern the tree already uses is a C++ `#ifdef` around
  the whole behaviour (clouds skipped, `sky_system.cpp:165`; object-distance
  cuts) — not a shader macro.

Ranking vocabulary: **clear win** = high confidence and low risk from the code
alone; **measure first** = plausible but the number depends on runtime state
(light count, water on screen, grass population) that must be read from
`boot.log`/`WORLD_PERF` before committing.

---

## Clear wins

### W1 — Cap the per-fragment local-light loop (HIGH)
`MAX_LOCAL_LIGHTS = 64` (`wowee/include/rendering/vk_frame_data.hpp:11`); the array
is filled each frame in `renderer.cpp:600-614`. Every terrain/M2/WMO/character
fragment runs:

```
for (int i = 0; i < min(localLightMeta.x, 64); ++i) { ... localLightPosRadius[i] ... }
```

- terrain.frag.glsl:155-172
- m2.frag.glsl:161-178
- character.frag.glsl (`localLightContribution`, called line ~349)
- wmo.frag.glsl (`localLightContribution`, called line 416)

The distance reject at line 169/163 avoids the `sqrt` but still executes 64
iterations, each pulling two `vec4`s from a 2 KB UBO range. On a 4-wide A57 this
is up to ~64 uniform loads + ~200 ALU per fragment over the **entire world**.
Run 63 found interiors draw *more* and cost *more* than outdoors — exactly the
regime where `localLightMeta.x` is large.

- **Impact:** HIGH in cities/inns/lamplit interiors (the known worst cases); LOW in
  open field. Multiplies the per-fragment cost of every world pipeline.
- **Quality/risk:** LOW risk. A smaller cap just drops distant lamp contribution.
- **Quick win vs larger:** Quick win — lower the constant under `WOWEE_SWITCH`
  (e.g. 16). Larger fix: build a per-object light list on the CPU so the loop
  bound is per-model, not global.
- **Switch-gate:** `vk_frame_data.hpp` already has `#ifdef WOWEE_SWITCH` precedent;
  one constant. No shader change needed because the bound is `min(meta.x, 64)`
  and `meta.x` is CPU-supplied (`renderer.cpp:604`) — lowering both makes the loop
  provably short without touching GLSL.

### W2 — Cheap cloud variant instead of a permanent skip (HIGH)
Clouds are **skipped wholesale** on Switch (`sky_system.cpp:165-175`) — a
diagnostic placeholder, not a feature. On desktop the fragment cost is the
heaviest single full-sky shader in the tree:

- `fbm()` = 5 octaves × `gradientNoise()` = 4 `hash2()` = **20 `hash2`/call**
  (clouds.frag.glsl:36-47), each `hash2` two `sin`+dot (15-19).
- Cumulus is domain-warped (clouds.frag.glsl:66-68): `fbm(p)`, `fbm(p+..)`,
  `fbm(p+q*1.4)` → 3 fbm. Plus erosion `fbm` (72) and the self-shadow re-sample
  `fbm` (95) → **6 `fbm` ≈ 120 `hash2` ≈ 240 `sin`** per pixel worst case; cirrus
  (77) adds 2 more `fbm` at the horizon.
- Then discard-driven shading at :52/:87/:118, a `pow(sunView, 6.0)` forward-scatter
  term (:108), and a `smoothstep` stack (:71,73,78,86,112).

The hemisphere covers roughly half of the 409 k fragments when looking up.

- **Impact:** HIGH (run 62: sky views are the slowest view). But this is a
  *placeholder*, so the fix is to re-enable a cheap layer.
- **Quality/risk:** MEDIUM — a cheaper cloud is visibly coarser. Mitigate with a
  density gate (skip when `density < 0.15`, `sky_system.cpp:179-184` already
  computes `effectiveDensity`) plus distance/altitude coverage.
- **Quick win vs larger:** Two steps. Quick: keep the skip but add the density
  gate so overcast zones get *some* cover back cheaply. Larger: a
  `clouds_switch.frag` variant — 2-octave **value noise sampled from a 128×128
  texture** (source from `celestial.frag`/`starfield` style value noise, or a
  baked noise asset), no domain warp, no separate `towardSun` shadow tap (fold
  the self-shadow into the same value read), drop cirrus. That is ~4 taps and
  ~20 ALU instead of ~240 `sin`.
- **Switch-gate:** new `.glsl`+`.spv` pair registered in `lighting_manifest.json`,
  selected by a C++ branch in `sky_system.cpp` (replacing the
  `loggedCloudSkip` block). The pipeline builder (`clouds.cpp:68`) already loads
  by path, so pointing at `clouds_switch.frag.spv` is a one-line change.

### W3 — Water foam/noise stack and the refraction copy (HIGH at water)
`water.frag.glsl` is 571 lines and the most expensive surface shader in the tree:

- Normal: `dualScrollWaveNormal` (63-95) → `noiseValue` (86) + 3 `cos`.
- Magma path (249-252): 2×`fbmGrad` (=3 `gradNoise` each) + 1 `gradNoise` ≈ 21
  hash evaluations.
- Shoreline sediment (387-388): 2× `noiseValue`.
- Shoreline foam (460-468): 2× `gradNoise` — runs for **every** water pixel with
  `0 < shoreDepth < 0.9`.
- Wake foam (500-519): 3× `noiseValue` + 2× `cellularFoam`; `cellularFoam` (213-229)
  is a 3×3 loop = **9 hash per call** → ~30 hash/pixel inside the wake radius.
- Crest foam ocean (535-542): 2× `noiseValue` + 1× `cellularFoam` + 1 `noiseValue`.
- Reads `SceneColor` (352), `SceneDepth` (332,345) and `ReflectionColor` (414).
  Sampling the scene colour while it is the scene target forces a **full-frame
  copy** (≈409 k × 4 B read + write ≈ 3.3 MB/frame) whenever `captureValid.x`
  (`push.captureValid`, 330) is set.

- **Impact:** HIGH at any water view — the sheet can cover most of the screen.
- **Quality/risk:** MEDIUM. Cutting `cellularFoam` for `gradNoise` changes foam
  character; cutting refraction loses the see-through shore.
- **Quick win vs larger:** Quick: gate the shoreline foam and both cellular
  foam passes off on Switch (they are already behind `push.waveAmp > 0` /
  `basicType` conditions — add the platform clause), and lower `fbmGrad` octaves.
  Larger: precompute a foam/noise texture atlas. Separately, disabling the
  refraction capture on Switch removes the copy.
- **Switch-gate:** two options. Lowest-risk is a **specialization constant**
  (`cellularFoam` on/off, foam on/off) because the branch is already
  `if (hasSceneData && ...)`. The refraction copy is a **C++ gate** — stop
  setting `push.captureValid.x` from the water renderer on Switch; the shader
  already has the `hasSceneData` fallback branch (331-333, 352-361).

### W4 — Draw the skybox after opaque geometry, not before (MED-HIGH)
`Skybox::render` draws a **fullscreen triangle** (`skybox.cpp:153`;
`skybox.vert.glsl:11`) with depth-test LEQUAL, write off, `gl_Position.z = 1.0`
(`skybox.cpp:67`), and it is emitted **first** by `SkySystem::render`
(`sky_system.cpp:110-112`). A fullscreen triangle shades all 409 k fragments every
frame, and most are immediately overdrawn by terrain/WMO/M2/water. Because depth
write is off and `z=1.0`, moving it to a **late pass after opaque geometry**
(let the depth test reject covered pixels) shades only the pixels that are
actually sky.

- **Impact:** MED-HIGH at horizon views (the worst case in run 62); a full-frame
  gradient + Rayleigh `pow(…,3)` + two Mie `pow(…,64/8)` + `exp` haze
  (skybox.frag.glsl:77-92) is saved for every covered pixel. No other pass is
  this cheap to reorder.
- **Quality/risk:** LOW. The sky is opaque (`outColor.a=1`, blend disabled),
  writes no depth, and sits at the far plane — draw order against it is a no-op
  once transparents sort correctly (clouds/M2 sky models still draw over it).
- **Quick win vs larger:** Quick win — reorder in `sky_system`/renderer. Larger:
  also fold the two `pow(…,64)`/`pow(…,8)` Mie terms into one `smoothstep` of
  `sunDot`.
- **Switch-gate:** reorder can be unconditional (correct on desktop too). If a
  desktop pass depends on the gradient being the clear, keep the draw first on
  desktop and last under `WOWEE_SWITCH`.

### W5 — Terrain per-fragment layer blur + derivative bump (MED)
`terrain.frag.glsl`:

- `sampleAlpha` (174-204) does a **4-tap separable blur** per layer near chunk
  edges, on top of the layer texture tap. Up to 3 layers → up to **3 base/1 base
  texture + 3 layer + 12 alpha = ~16 texture taps per terrain fragment**.
- Derivative bump (236-251): `dFdx/dFdy(FragPos)` + `dFdx/dFdy(lum)` = 5 derivative
  ops + 2 crosses + normalise, active within 125 yd (`bumpFade`, 237).
- Shading (253-268): diffuse + shadow + `localLightContribution` + fog.

Run 60 called terrain "base cover fixed cost," which is true for **draw count** —
but the taps and derivatives still scale with **pixels**, and terrain fills most of
a ground-facing frame.

- **Impact:** MED (steady, everywhere).
- **Quality/risk:** MEDIUM. The blur hides chunk-seam alpha steps; the bump adds
  surface detail. Both are visible if removed abruptly.
- **Quick win vs larger:** Quick: on Switch, return `center` immediately from
  `sampleAlpha` (the `blurWeight < 0.001` early-out at 184 already exists — force
  it) and skip the bump block. Larger: bake the alpha blur into the 64×64 mask at
  upload (`terrain_renderer.cpp` already normalises masks on Switch).
- **Switch-gate:** the blur is a self-contained function — a specialization
  constant `kTerrainAlphaBlur` set to 0, or a `terrain_switch.frag` variant.

### W6 — M2 foliage per-fragment extras (MED)
Foliage is alpha-heavy overdraw, and the M2 shader adds per-fragment work only
for it:

- DXT-fringe repair `textureLod(uTexture, ..., 4.0)` for any `0.01 < a < 1`
  (m2.frag.glsl:264-269) — an extra tap on every semi-transparent texel.
- `textureQueryLod` mip-alpha boost (274-277).
- Per-instance hue/brightness hash with two `sin` (298-304).
- Foliage normal perturbation, two `sin` (310-314).
- Canopy AO smoothstep (371-375).

- **Impact:** MED (foliage overdraw concentrates these).
- **Quality/risk:** LOW-MEDIUM; the hue variation and perturbation are cosmetic.
- **Quick win vs larger:** Quick: skip the `mipColor` repair and the normal
  perturbation on Switch (both are already guarded by `alphaMode`/`isFoliage`
  branches). Larger: pack foliage leaf colour into the vertex stream.
- **Switch-gate:** specialization constant `kFoliageDetail` = 0, or gate the C++
  that sets `normalMapStrength`/`interiorDarken` — but the repair tap is a shader
  branch, so a variant is the clean answer.

### W7 — `discard` forces full shading on the sky hemisphere (MED)
`discard` (clouds.frag:52/87/118, celestial.frag:31/102, starfield.frag:11,
m2.frag:257/288/293/295, water alpha) disables early depth rejection on the
affected triangles, so a hemisphere that would mostly be hidden still shades in
full. This compounds W4 (sky drawn first) and W2.

- **Impact:** MED — only matters where the geometry is mostly covered.
- **Quality/risk:** LOW if solved by ordering (W4) rather than removing discards.
- **Switch-gate:** covered by W4; no separate change.

---

## Measure first

### M1 — Vertex-format tightening (LOW, quantifiable)
`TerrainVertex` (`pipeline/terrain_mesh.hpp:16-24`) is
`position 3f` 12 + `normal 3f` 12 + `texCoord 2f` 8 + `layerUV 2f` 8 + `uint8_t
chunkIndex` = **41 bytes, padded to 44** (comment: `terrain_vertex.hpp:16-19`,
"the trailing `chunkIndex` byte pads out to 44"). The shader declares only
locations 0-3 (`kTerrainVertexAttributes`, `terrain_vertex.hpp:22-27`) — the
`chunkIndex` byte is **never read by the vertex shader**. WMOVertex is 64 B
(`wmo_vertex.hpp:21-28`), M2VertexDisk 48 B (`m2_loader.cpp:120`), character
vertex carries pos+weights+indices+normal+uv+tangent.

Quantified: 44 → 41 by deleting `chunkIndex` (−7%); 44 → 32 by packing both UV
sets to `R16G16_SFLOAT` and normal to `R10G10B10A2` (−27%). At a *generous*
~500 k terrain verts/frame, 44 B = ~22 MB/frame of vertex fetch, and 32 B saves
~6 MB/frame — against a ~25 GB/s budget and a **fill-bound** GPU this is noise
unless the vertex stage is unexpectedly the wall. **Measure `TERRAIN_DIAG`
draw/vertex counts in `boot.log` before touching this**; treat the win as a
packaging/CPU-bandwidth nicety, not a frame-time one.

- **Switch-gate:** none needed; a pure layout change, but it moves offsets that
  three parties must agree on (`vertex_layout.hpp` doc) — the test that compares
  layout to shader source is the guard.

### M2 — `localLightContribution` real light counts (feeds W1)
The loop bound is `min(localLightMeta.x, 64)`; the actual `localLightCount` is
logged at `renderer.cpp:637` (`localLights: count=… of 64`). Read that line from a
city/inn run to size W1's win before committing.

### M3 — Water on screen (feeds W3)
Whether the refraction capture (`captureValid.x`) is set and how much of the frame
is water determines whether the copy dominates. Confirm from a water view's
`WORLD_PERF` before disabling refraction.

### M4 — Grass overdraw
`GrassRenderer` (`grass_renderer.cpp`) draws blades with `grass.frag.glsl` (69
lines, wrapped-diffuse, cheap per blade) but alpha/discard overdraw can be large.
Confirm whether grass populates on Switch and its instance count (it logs blade
count at `grass_renderer.cpp:568`) before gating.

### M5 — FXAA cost
FXAA runs because scene extent (853×480) ≠ output extent (720/1080)
(`post_process_pipeline.cpp:64-69`, `desiredSceneExtent`). It is ~5 taps on smooth
pixels and up to 13 + a 12-step search on edge pixels (fxaa.frag.glsl:133-141),
over 409 k fragments. It is the only AA on Switch, so this is a quality trade, not
a free win — measure its share before considering removal.

---

## Ranked shortlist

| # | Change | Class | Impact | Risk | Evidence |
|---|--------|-------|--------|------|----------|
| 1 | Cap `MAX_LOCAL_LIGHTS` (e.g. 16) on Switch | clear win | HIGH (lit/interior) | LOW | vk_frame_data.hpp:11, terrain.frag:155, m2.frag:161, wmo.frag:416, char.frag |
| 2 | Gate water foam/cellular noise + disable refraction copy | clear win | HIGH at water | MED | water.frag:249-252,460-468,500-519,535-542,330,352 |
| 3 | Cheap `clouds_switch` variant (or density gate) | clear win | HIGH at sky | MED | clouds.frag:36-95, sky_system.cpp:165 |
| 4 | Draw skybox last (depth-tested), not first | clear win | MED-HIGH horizon | LOW | skybox.cpp:67,153, sky_system.cpp:110 |
| 5 | Drop terrain alpha 4-tap blur + derivative bump on Switch | clear win | MED | MED | terrain.frag:174-204,236-251 |
| 6 | Skip M2 foliage repair tap / perturbation / hue | measure/win | MED | LOW-MED | m2.frag:264-269,298-314,371-375 |
| 7 | Housekeeping: `FINDINGS`/AGENTS confirm the cloud skip is temporary | clear win | — | — | sky_system.cpp:168-175 |
| 8 | Vertex-format tightening (44→41→32 B) | measure | LOW | LOW | terrain_mesh.hpp:16-24, terrain_vertex.hpp:16-19 |
| 9 | FXAA tap budget / merge during sky pass | measure | LOW-MED | MED | fxaa.frag:62-141 |
| 10 | Fold skybox Mie `pow(64)/pow(8)` into one term | measure | LOW | LOW | skybox.frag:85-88 |

## Notes for the implementer

- **No GLSL `#ifdef`.** Any per-platform shader branch must be a second
  `.glsl`+`.spv` pair registered in `assets/shaders/lighting_manifest.json`
  (checked by `wowee/tools/switch/verify_shaders.py`), or a Vulkan specialization
  constant in an existing pair. The C++ builders select variants by path
  (`clouds.cpp:68`, `skybox.cpp:40`) — reusing that is the least invasive route.
- **Prefer the specialization constant** for W1 (loop bound), W2/W5/W6 (boolean
  detail toggles): it keeps one source of truth for the shader and one manifest
  entry, and avoids a second SPIR-V to hash.
- **Remove the temporary `[WOWEE_*]` instruments** (there are none in shaders
  today, but `TERRAIN_DIAG`/`clouds skipped` logs are the debug-round scaffolding
  named in AGENTS.md) once W1-W4 land.
- Everything here is read-only analysis; no files outside this report were
  modified.
