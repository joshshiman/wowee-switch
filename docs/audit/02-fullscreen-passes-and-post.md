# Audit 02 — Full-screen Passes, Post-processing, Render Scale

Scope: every full-screen (whole-target) render pass and image copy that still
executes **in-world on Switch**, the post-processing chain, render-scale, shadows,
volumetric, bloom, FSR/FXAA/MSAA, HDR/format and depth/stencil choices, and the
render-graph pass structure. Inputs audited: `renderer.cpp` pass wiring,
`post_process_pipeline.{cpp,hpp}` + `post_process_{bloom,volumetric}.inc`,
`render_graph.{cpp,hpp}`, `switch_scene_extent.hpp`, `vk_context.cpp` render
passes/formats, `vk_render_target.*`, `water_renderer.cpp` scene-history path,
`assets/shaders/fxaa.frag.glsl`.

Method: static read of the shipped code on branch `perf/switch-audit`. No console
run. Every cost is priced at the **measured Switch profile**: world renders
off-screen at **853×480** (`switch_scene_extent.hpp:29` → `return 480`;
`fitSwitchSceneExtent` at `:67` gives width `1280*480/720 = 853`), the UI and
output stay native **1280×720** (`vk_context.cpp:2312-2384`). At 4 B/px that is
**scene 409 k px = 1.64 MB**, **output 921 k px = 3.69 MB** per full R8G8B8A8 target.

Ranking vocabulary: **clear win** = high confidence, low risk from code alone;
**measure first** = plausible but the runtime number (water on screen, saved
settings) must be read from `boot.log`/`WORLD_PERF` before committing.

---

## 0. What is already off (verified, do not re-cut)

The "switch performance floor" lives in two places; both are live and effective:

- Startup force: shadow quality 0 at `renderer.cpp:812-822`, and
  volumetric/bloom off at `renderer.cpp:1031-1042`.
- Setting sinks (the choke point every route passes through — startup, saved
  CVar, Lua, panel): `setShadowQuality→0`, `setVolumetricQuality→0`,
  rays/fog/bloom→false at `renderer.cpp:839-886`.

Consequently, in-world the following are **not** costing anything:

- **Bloom** — `renderBloom()` early-outs (`post_process_bloom.inc:172-175`) *and*
  `manageResources` destroys its render passes/images when `needBloom` is false
  (`post_process_pipeline.cpp:166-171`), so there is no resident target either.
- **Volumetric** — `renderVolumetricScattering()` early-outs at `quality==0`
  (`post_process_volumetric.inc:315-321`); resources destroyed
  (`post_process_pipeline.cpp:155-165`).
- **FSR1 / FSR2 / FSR3 framegen** — hard-disabled on Switch (`setFSREnabled`
  `post_process_pipeline.cpp:553-558`, `setFSR2Enabled` `:597-604`). `fsr_`/`fsr2_`
  never allocate; the whole FSR branch (`:302-433`, `:481-521`) is dead.
- **Water planar reflections** — `renderReflectionPass` returns immediately on
  Switch because `extWaterReflections` defaults `"0"` (`renderer.cpp:4615-4622`);
  `renderShadowPass`'s reflection-receiver block is likewise gated
  (`:4813-4829`).
- **MSAA** — `msaaSamples_` defaults to 1 (`vk_context.hpp:583`) and the Switch
  default anti-aliasing choice is Off (`graphics_defaults.hpp:22`,
  `kDefaultAntiAliasing = 0`). This matches the measured `msaa=1` in the ledger.

The remaining in-world full-screen work is therefore: the scene pass, the shadow
atlas clear, the water-refraction copy + continue pass, the FXAA/upscale pass,
and the UI overlay pass. That is what this audit prices.

---

## Clear wins

### W1 — Shadow atlas is cleared and barrier-transitioned every frame at quality 0 (MEDIUM)
`buildFrameGraph` keeps `shadow_pass` enabled whenever the image exists
(`renderer.cpp:5006-5008`), and `renderShadowPass` deliberately runs even with
shadows off: `drawCasters=false` (`:4722`) but it still barriers the map
(`:4739-4762`), **begins the pass and clears a 1024×512 D32 atlas**
(`:4764-4774`; `SHADOW_MAP_SIZE=512` on Switch → `1024×512`), then barriers again
(`:4903-4923`). Nothing is drawn into it at quality 0.

- Cost: a **2.10 MB depth clear** + 2 image barriers + begin/end, every frame,
  for zero casters.
- Why it exists: the comment at `:4713-4721` says the pass is what leaves the
  image in the layout its readers expect. But the readers already skip it:
  `shadowParams.x = shadowsEnabled ? 1 : 0` (`renderer.cpp:596-598`), and the
  four receiving shaders test that. So at quality 0 the atlas is never sampled.
- **Clear win:** when `!shadowsEnabled` (quality 0), skip `shadow_pass`
  entirely and leave the atlas permanently in `SHADER_READ_ONLY_OPTIMAL` (or leave
  it `UNDEFINED` and transition once on the first shielded frame). One `#ifdef`
  guard + a setPassEnabled condition.
- **Quality/risk:** none visible; shadows are off. Risk is the layout assumption
  the comment warns about — verify a re-enable mid-session still transitions
  correctly, or keep the first-frame transition.
- **Switch-gate:** pure C++ `#ifdef WOWEE_SWITCH` at `buildFrameGraph`.

### W2 — FXAA/upscale pass and the UI pass are two overlay passes; merge them (MEDIUM)
With the 480p scene, `needsFXAAPass()` returns true purely because scene extent
≠ output extent (`post_process_pipeline.cpp:60-72`). In `executePostProcessing`
the FXAA branch ends the scene/continue pass, picks up
`getOverlayClearRenderPass()` (**clearOp = CLEAR**, `vk_context.cpp:2362-2363`),
clears the whole 720p image, draws the upscale, and leaves the pass open returning
`inlineMode=true` (`:434-479`). Then `endFrame` immediately ends that pass
(`renderer.cpp:1746`) and **begins a second overlay pass** with `LOAD`
(`getOverlayRenderPass`, `vk_context.cpp:2318`) just to draw ImGui
(`renderer.cpp:1765-1818`). The two passes are render-pass-compatible (load/store
ops don't affect compatibility), so the upscale could be drawn into the `LOAD`
overlay pass and the UI appended to it.

- Cost of the redundant half: one **3.69 MB 720p clear** + one render-pass
  begin/end.
- Why the clear exists: the loading screen draws ImGui with nothing underneath
  (`vk_context.cpp:2358-2361`) — that is a menu-time case, not in-world, where the
  upscale covers every pixel.
- **Clear win:** in-world, use `getOverlayRenderPass()` (LOAD) for the FXAA/upscale
  draw and let `endFrame` skip its own second begin when the pass is already open;
  keep `overlayClearRenderPass` for the loading/menu path.
- **Quality/risk:** low. Requires threading an "overlay pass already open" flag
  from `executePostProcessing` to `endFrame`. The water-refraction copy that
  motivates a separate pass already runs earlier, inside `renderWorld`.
- **Switch-gate:** C++ only; desktop keeps the two-pass shape if preferred.

### W3 — Water refraction copy + continue pass run every frame whether or not water is visible (MEDIUM)
`waterDrawsInContinuePass()` is true whenever `sceneContinueRenderPass != null`
(i.e. MSAA off, `renderer.cpp:3794-3803`). So in `renderWorld`, **every frame**:
the scene pass is ended (`:3531`), `captureSceneHistory` copies **scene colour
(1.64 MB) into history and scene depth (1.64 MB) into history**
(`water_renderer.cpp:1300-1466`, ~8 barriers), and a **continuation pass begins
with `LOAD` on colour+depth** (another 1.64+1.64 MB) to draw water
(`renderer.cpp:3564-3581`). Refraction is hard-wired on
(`setWaterRefractionEnabled` ignores its argument, `renderer.cpp:1257-1261`), and
`hasSurfaces()` (`water_renderer.hpp:141`) — which only means "some surface is
loaded" — is **not** consulted on this path.

- Cost: ~**6.5 MB transfer** (colour+depth copy) + ~**3.3 MB attachment load** +
  begin/end, on every frame in every zone, including interiors and zones with no
  water.
- **Clear win (partial):** gate the capture and the continuation pass on a real
  visibility test (at least `hasSurfaces()`, better a frustum/dominant-height
  check like the reflection pass already does). The endFrame refraction copy is
  already gated on `isRefractionEnabled() && hasSurfaces()`
  (`renderer.cpp:1753-1763`); the renderWorld path is not.
- **Quality/risk:** low if gated on visibility; a missed surface means one frame
  of unrefracted water.
- **Switch-gate:** C++ `#ifdef WOWEE_SWITCH` around the two consumption sites, or a
  shared helper.

### W4 — No Switch floor on MSAA / saved anti-aliasing (MEDIUM, latent)
`applySavedAntiAliasing` applies any saved `antialiasing > 0` with no Switch guard
(`game_screen.cpp:185-190`), called from `application.cpp:319,2867`; the panel
path is likewise unguarded (`settings_panel.cpp:1259`). Because
`desiredSceneExtent()` only returns the 480p profile when
`msaaSamples == VK_SAMPLE_COUNT_1_BIT` (`post_process_pipeline.cpp:53-55`),
enabling MSAA would both **quadruple scene fill** (MSAA attachments at
`vk_context.cpp:2015-2059`) **and silently abandon the render-scale** back to
native — the worst possible combination on this GPU. Today the default is Off
(`graphics_defaults.hpp:22`) and the ledger measured `msaa=1`, so this is latent,
not active.

- **Clear win:** add the same sink-style floor used for shadows — force
  `VK_SAMPLE_COUNT_1_BIT` in `Renderer::setMsaaSamples` under `WOWEE_SWITCH`
  (`renderer.cpp:1263-1278`), so every route (startup, panel, CVar) is covered.
- **Quality/risk:** none; MSAA is off already.
- **Switch-gate:** one `#ifdef` in `setMsaaSamples`.

### W5 — Full FXAA 3.11 math runs at 720p when the saved `fxaa=1` (LOW–MEDIUM)
The pass always runs on Switch (it *is* the upscale). When `fxaa_.enabled` is
false it takes the cheap bypass — `sharpness = -1` and the shader returns after a
single tap (`post_process_pipeline.cpp:1996-1998`, `fxaa.frag.glsl:58-61`) — so
disabling FXAA costs nothing visually. When a saved `fxaa=1` enables it,
`renderFXAAPass` runs the full kernel: **12 search steps + up to ~20 texture
taps per output pixel at 720p** (`fxaa.frag.glsl:133-157`), on a 25 GB/s GPU,
before the UI.

- **Clear win:** force `fxaa_.enabled = false` on Switch (the upscale is
  unaffected). Same one-line sink treatment as bloom/volumetric.
- **Quality/risk:** loses edge smoothing for anyone who opted in; the 480p→720p
  upscale is already soft, so the perceived difference is small.
- **Switch-gate:** `setFXAAEnabled` `#ifdef WOWEE_SWITCH`.

---

## Measure first

### M1 — Cheaper or merged upscale path
A scaled `vkCmdBlitImage` would fold the upscale into the copy, but the code
states explicitly that nxvk **rejects scaled tiled copies**
(`water_renderer.cpp:1312-1321`, `post_process_pipeline.cpp:598-604`), and the
full-screen triangle with dynamic viewport is the supported path
(`post_process_pipeline.cpp:1977-2009`). Do not chase blit-upscale. What *is*
worth measuring is whether the FP32 **scene depth** can share a cheaper format
(M2).

### M2 — D32_SFLOAT depth at 4 B/px, no stencil used
`depthFormat = VK_FORMAT_D32_SFLOAT` (`vk_context.hpp:577`), and no code path
uses a stencil aspect. Depth is cleared, stored, and **copied to history every
frame** (M3/W3). A `D16_UNORM` target would halve the depth clear/store/copy
bandwidth (scene depth 1.64 → 0.82 MB ×2). Risk: the world uses large
coordinates and long view distances; 16-bit depth may z-fight. **Measure first**
— only worth it if the profile ever shows the scene pass is depth-bandwidth
bound, which the ledger does not currently support.

### M3 — Continuation-pass `LOAD` could be `DONT_CARE` when no water draws
Even if W3's visibility gate is not taken, the continuation pass at
`renderer.cpp:3564-3569` uses `sceneContinueRenderPass` (`loadOp = LOAD`,
`vk_context.cpp:2403`) for both colour and depth. On a tiled GPU this forces the
full attachment residency. If the water draw is empty (no surfaces visible),
`DONT_CARE` would avoid the load. Verify on hardware — the pass still must not
lose the scene it is continuing, so this only applies when nothing is drawn.

### M4 — Render-graph virtual resources registered but never wired as edges
`renderer.cpp:1068-1072` registers `shadow_depth`, `reflection_texture`,
`scene_color`, `scene_depth`, `final_image`, but `buildFrameGraph` only connects
`shadow_depth` and `reflection_texture` to the `shadow_pass`/`reflection_pass`
nodes (`:4948-5001`); `scene_color`/`scene_depth`/`final_image` have no pass that
declares them. This is **not** a runtime cost (registration is a vector push,
graph is compiled once, `render_graph.cpp:57-114`), but it means the graph does
**not** currently model the scene/upscale/UI passes — so it cannot be used to
detect or eliminate them. Worth knowing before building any pass-fusion on it.

### M5 — Per-frame pre-pass composites (minimap / world map / previews)
`buildFrameGraph` executes `minimap_composite` (gated on `minimap->isEnabled()`),
`worldmap_composite`, and `preview_composite` (gated on loaded previews) every
frame (`renderer.cpp:4951-4976`). These target small fixed-size off-screen
targets (minimap composite is `COMPOSITE_PX`, `minimap.cpp:86-88`), not full
screen, so the cost is low — but confirm from `WORLD_PERF` before assuming they
are free, since they add render-pass begins and copies to the frame.

---

## Reference: in-world full-screen pass inventory at 853×480 / 1280×720

| # | Pass / copy | Target px | Bandwidth (approx) | Active on Switch? |
|---|-------------|-----------|--------------------|-------------------|
| 1 | Scene pass (colour+depth) | 853×480 | clear 1.64+1.64 MB, store 1.64+1.64 MB | yes |
| 2 | Shadow atlas clear | 1024×512 D32 | 2.10 MB clear, no draws | yes, wasted at q0 (W1) |
| 3 | Water refraction colour+depth copy | 853×480 | ~6.5 MB transfer | yes, unconditional (W3) |
| 4 | Scene continue pass (water) | 853×480 | load 1.64+1.64 MB | yes, unconditional (W3) |
| 5 | FXAA/upscale → overlay clear | 1280×720 in, 853×480 sampled | clear 3.69, read 1.64, write 3.69 MB | yes; clear redundant (W2) |
| 6 | UI overlay pass | 1280×720 | load 3.69 MB | yes |
| — | Bloom extract+blur+composite | quarter-res | — | no (destroyed) |
| — | Volumetric march+resolve+composite | quarter/half | — | no (destroyed) |
| — | Planar reflection scene re-render | native | — | no (CVar default 0) |
| — | FSR upsample | — | — | no (blocked on nxvk) |

---

## Ranked shortlist

1. **W1 — Skip the quality-0 shadow clear+pass.** Zero-vister, one `#ifdef`;
   removes 2.1 MB/frame + 2 barriers. *(clear win, quick)*
2. **W2 — Merge the FXAA/upscale overlay pass with the UI overlay pass.**
   Removes a 3.69 MB 720p clear and a render-pass begin/end. *(clear win, medium)*
3. **W3 — Gate the water refraction copy + continuation pass on water visibility.**
   ~9.8 MB/frame in every water-less frame. *(clear win, quick-to-medium)*
4. **W4 — Add the Switch floor to `setMsaaSamples`.** Closes a latent route that
   would quadruple fill *and* drop the render scale. *(clear win, one line)*
5. **W5 — Force FXAA off on Switch.** Removes the ~20-tap 720p kernel; upscale is
   unaffected. *(clear win, one line)*
6. **M2 — Evaluate D16 depth** if depth bandwidth ever shows up. *(measure first)*
7. **M3 — `DONT_CARE` on the empty continuation load.** *(measure first)*
8. **M5 — Confirm the per-frame minimap/worldmap/preview composites cost.** *(measure first)*

Note: this profile already spends its biggest lever — the 480p render scale
(W1–W5 above only trim the passes *around* the scene draw). The scene pass
itself (#1) is where the remaining ~130 ms of run 50 lives, and that is the
shader/overdraw domain of audit 09, not this one.
