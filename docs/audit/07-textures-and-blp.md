# Audit 07 — Texture loading, decode, upload and residency

Scope: BLP decode cost, mip generation, format selection, staging/upload,
caching/eviction, duplicate decode/upload, sRGB, the alpha path. Read-only;
measured against the source on branch `perf/switch-audit` (2026-10-11).
Companion to `docs/FINDINGS.md` §2 (memory ceiling) and §7 (post-Run-50).

**Central fact.** On Switch every world texture is decoded to RGBA8 and has its
whole mip chain rebuilt on the CPU, on the render thread, inside the upload
call. The compressed path exists and is fully implemented but is force-disabled
by one line. The four renderers' texture caches are budgeted at ~20 GiB
combined and never actually evict by use, so residency only grows until the
heap refuses an allocation — which is the documented cause of "textures went
white" (FINDINGS Run 39).

---

## How a texture moves today

1. Renderer cache lookup, keyed by lower-cased backslash path
   (`terrain_renderer.cpp:752`, `m2_renderer_instance.cpp:764`,
   `wmo_renderer.cpp:3075`, `character_renderer.cpp:859`).
2. On miss, read bytes (MPQ/loose) + `BLPLoader::load` with `keepCompressed`
   (terrain `terrain_manager.cpp:597`, M2 `:734`, WMO `:3120`) or without
   (character `character_renderer.cpp:883`).
3. `VkTexture::uploadBLP` (`vk_texture.cpp:580`). On Switch
   `ctx.isBlockCompressionSupported()` is false, so every DXT image takes the
   fallback at `vk_texture.cpp:590-598`: `decodeBaseLevel` (RGBA alloc + decode,
   main thread) then `upload(..., generateMips=true)`.
4. `upload()` takes the Switch branch at `vk_texture.cpp:94-209`: builds the
   entire mip chain with a scalar 4-sample box filter over freshly allocated
   `std::vector` per level, then `uploadMips` submits it.
5. GPU image is `R8G8B8A8_UNORM` base + CPU mips.

UI textures are separate: `BLPLoader::load` (full decode) → either
`VkContext::uploadImGuiTexture` (`vk_context.cpp:2577`, raw `vkAllocateMemory`,
no mips, no VMA, no reclaim retry) or `makeImGuiTexture`
(`imgui_texture.cpp:36`, `generateMips=false`).

---

## CLEAR WINS (ranked)

### W1. Turn BC1/BC2/BC3 back on (or make it a live experiment) — HIGH

Evidence: `vk_context.cpp:662-669` hardcodes `blockCompressionSupported_ = false`
with the comment "The B11 hardware log rejects BC mip tails in GpuAddress
tiling. A failed copy also poisons other uploads in its batch." The consumer
side is complete and tested: `BLPLoader::loadBLP2` collects stored levels
(`blp_loader.cpp:362-417`), `uploadBLP` maps DXT1/3/5 → `VK_FORMAT_BC*_UNORM_BLOCK`
and gates on `VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT` (`vk_texture.cpp:600-614`),
`uploadMips` uploads per-level with block-aligned offsets, and a byte tally is
kept (`vk_texture.cpp:569-578, 634-637`).

Why it matters (quantified for a 1024×1024 texture, from the code's own
arithmetic in `blp_loader.hpp:66-85`):
- RGBA + CPU mips GPU residency: `4·W·H·(1+1/3)` = **5.33 MiB**.
- BC1 + file mips: `0.5·W·H·(4/3)` = **0.67 MiB** (8×).
- BC2/BC3 + file mips: `1.0·W·H·(4/3)` = **1.33 MiB** (4×).
- Plus the decode (`blp_loader.cpp:103-111`, a fresh `W·H·4` alloc) and the
  whole CPU mip chain (`vk_texture.cpp:151-190`) disappear on this path because
  the file already carries the levels. Peak transient per texture drops from
  ~2.33·W·H·4 (~9.3 MiB, plus ~10 vector allocations) to zero.

Impact: high — memory, sampling bandwidth, CPU, and allocation churn all at
once, on the single hardest constraint in the port (§2).
Quality/risk: high risk. The failure is content/driver-specific (BC mip tails),
not a code bug, and a bad copy poisons the batch (`vk_texture.cpp:364-390`,
`vk_context.cpp:665-667`). Do not flip it globally on a whim.
Quick win vs larger: larger. The code is ready; the *validation* is the work.
Smallest safe step: a runtime/env toggle that enables BC, uploads only the base
level first (mipLevels=1), and logs the tally — this isolates whether the
rejection is specifically the mip tail rather than BC as a whole, matching the
"B11 mip tail" observation exactly. If base-only BC is clean, a follow-up can
add tails.
Switch-gate: Switch-specific. Desktop already reports BC support
(`vk_context.cpp:738-740`) and keeps `keepCompressed`.

### W2. Decode + mip-build off the render thread — HIGH

Evidence: the CPU mip chain is unconditionally built on the calling thread
(`vk_texture.cpp:94-209`); `decodeBaseLevel` runs on the main thread in the
fallback (`vk_texture.cpp:594`). The background workers *prefetch bytes*, not
pixels: terrain/M2/WMO store compressed blocks
(`terrain_manager.cpp:592-598, 632-653, 732-738`), and character/creature loads
decode on the async future but store the result for a *main-thread* re-upload
(`entity_spawner_processing.cpp:798, 811, 1059`). So the expensive part — RGB
decode and the box filter — is still on the frame thread.

Cost estimate: for one 1024² DXT image, ~1.0 M pixels of block decode plus
~1.33 M output pixels × 4 channels × 4 source samples ≈ 20 M+ scalar ops, with
~10 per-level heap allocations. On an A57 at ~1 GHz that is order 10-30 ms per
large texture; dozens per tile. This is consistent with the "SLOW update
60-75 ms" streaming hitches in FINDINGS Run 61, and the world-load stalls in
Run 48.

Quality/risk: medium. Feeding final RGBA+mips to the renderer raised peak heap
before (comment at `asset_manager.cpp:559-562`: "Expanding every terrain/WMO
texture here retained an entire tile's decoded pixels and exhausted the
flexible heap"). The fix is not "decode a whole tile"; it is "build the level
list for one texture on a worker and hand the finished `VkTexture` staging to
the main thread", preserving the one-at-a-time bound.
Quick win vs larger: larger, but a partial quick win exists — move just
`decodeBaseLevel` into the worker that already fetched the blocks, and keep the
mip build main-thread until that is validated.
Switch-gate: Switch-specific; the branch at `vk_texture.cpp:94` is already
`#if defined(WOWEE_SWITCH)`.

### W3. Give the texture caches a console budget and real eviction — HIGH

Evidence: four independent budgets default to desktop-sized values —
terrain 4096 MiB (`terrain_renderer.cpp:219-220`), M2 4096
(`m2_renderer.cpp:1106-1107`), WMO 8192 (`wmo_renderer.cpp:408-409`),
character 4096 (`character_renderer.cpp:499`) = **~20 GiB of budget on a
~1.8 GiB shared heap**. `lastUse` is written on every hit but never read for
eviction. When a budget *is* hit, the code rejects the new texture and returns
white (`terrain_renderer.cpp:776-784`, `m2_renderer_instance.cpp:809-824`,
`wmo_renderer.cpp:3145-3158`, `character_renderer.cpp:898-914`) instead of
evicting the coldest entry. The only reclamation is reference-based orphan
sweeps (`m2_renderer_instance.cpp:708-729`, `terrain_renderer.cpp:1429-1462`),
so anything still referenced is retained for the session.

Impact: high — this is the mechanism by which residency grows until
`createImage` is refused and surfaces go white (FINDINGS Run 39), and it is the
direct cause of the memory ceiling being "not exhaustion, but full for an
instant" (§2).
Quality/risk: low risk if eviction is reference-aware (do not evict a texture a
live chunk/batch still points at — the orphan sweep already knows the
referenced set). Wrong eviction = a texture popping white on a live surface.
Quick win: yes — cap the four budgets on Switch (e.g. a shared 128-192 MiB,
sized like the terrain/descriptor work in Runs 40-44) and add LRU eviction
driven by the already-present `lastUse`. Measuring resident bytes per renderer
is one log line the code already emits on shutdown.
Switch-gate: Switch only; desktop budgets should stay.

### W4. Route UI textures through VMA and give them mips — MEDIUM

Evidence: `VkContext::uploadImGuiTexture` (`vk_context.cpp:2577-2660`) uses raw
`vkCreateBuffer`/`vkAllocateMemory`/`vkBindBufferMemory` and creates a
`mipLevels = 1` image, with no reclaim-and-retry and no entry in the VMA stats
that every other allocation path now relies on. `WidgetRenderer::texture`
(`widget_renderer.cpp:169-207`) and `ui_texture_load.cpp:24-34` both fully
decode the BLP first (`BLPLoader::load`, no keepCompressed), and
`makeImGuiTexture` uploads with `generateMips=false` (`imgui_texture.cpp:36`).
Glue/loading backgrounds and widget art can be 1024×512+, so this is where the
largest unconditioned UI allocations land.

Impact: medium — a handful of MiB each, plus no minification filtering
(shimmer on scaled art), plus these allocations are invisible to the memory
budget/layout diagnostics that drive every other fix.
Quality/risk: low — routing through the existing `VkTexture`/VMA path is
mechanical; adding mips changes filtering and needs a visual check.
Quick win: yes for the VMA routing; mips is a small follow-up. Also a natural
place to downscale glue backgrounds on Switch (handheld is 720p; a 1024×512
glue texture has no more detail to give at native size).
Switch-gate: Switch benefits most, but it is a general robustness improvement.

---

## MEASURE FIRST

### M1. Duplicate decode/upload across renderers — measure overlap

Each renderer owns a private cache (`terrain_renderer.cpp:752`,
`m2_renderer_instance.cpp:764`, `wmo_renderer.cpp:3075`,
`character_renderer.cpp:859`). The same path used by both a doodad (M2) and a
building (WMO) is decoded and uploaded twice. Impact unknown without a hit
counter across caches; likely low (texture namespaces overlap modestly).
Risk: a shared cache needs one clear owner and lifetime across renderer
shutdowns. Measure first (log distinct keys seen by 2+ caches).

### M2. sRGB is deliberately absent — do not change one side

The swapchain is `B8G8R8A8_UNORM` (`vk_context.cpp:1474`), textures are
`R8G8B8A8_UNORM` or `BC*_UNORM` (`vk_texture.cpp:587, 602-604`), and no shader
does a gamma step. The whole pipeline is consistently "UNORM bytes passed
through". Do **not** switch only the block formats to `BC*_SRGB` when W1 lands —
that would wash the world out against the UNORM swapchain. Treat sRGB as a
coupled, whole-pipeline decision, not a texture-local one ("measure first",
then likely leave alone).

### M3. Mip residency / dropping top levels — low

Samplers already set `maxLod` to the full chain (`vk_texture.cpp:706, 733`).
Selective mip dropping (e.g. skip levels below 1×1 for distant tiles) would
trade memory for shimmer and duplicates what distance culling already does.
Not worth it while the format lever (W1) is untried. The alpha textures are
already mip-less by design (`generateMips=false`,
`terrain_renderer.cpp:877, 913`) — leave them.

### M4. Character textures ignore `keepCompressed` even where BC works — low

`character_renderer.cpp:883` calls `loadTexture` without the flag and
`character_renderer.cpp:917-922` scans every 4th byte for alpha instead of
`BLPImage::hasTransparency()` (`blp_loader.hpp:61`). On Switch this is
moot while BC is off; on desktop it wastes the block path for sampled skins.
Low priority, folds into W1/W2.

### M5. Alpha path is already good — no action

Terrain alpha masks are 64×64 `R8_UNORM`, deduplicated by content via
`TerrainAlphaCache` and shared with 1×1 opaque/transparent fallbacks
(`terrain_renderer.cpp:854-930`). This is the one texture path already
right-sized for the console; note it and move on.

---

## Ranked shortlist

1. **W3 — budget + LRU evict the four texture caches.** Highest
   impact-per-risk; purely CPU-side, no format gamble, directly attacks the
   measured ceiling. Quick win.
2. **W1 — re-enable BC as a base-level-only instrumented experiment.** Biggest
   possible payoff (4-8× residency and bandwidth, no CPU decode/mips), but must
   be validated against the B11 mip-tail rejection. Larger.
3. **W2 — move decode + mip build to the streaming workers.** Kills the
   60-75 ms streaming hitches; larger, and must respect the one-texture-at-a-time
   memory bound. Larger.
4. **W4 — VMA + mips (and optional downscale) for UI/glue textures.** Robustness
   and a few MiB. Quick win.
5. **M1 / M4 — cross-renderer dedup and character-block path.** Only after the
   above, and only with a measured overlap. Measure first.
6. **M2 / M3 — sRGB and mip residency.** Note and leave; no change without a
   coupled whole-pipeline decision.

**Do-not-touch:** the 64×64 R8 alpha path (M5), and any switch of only the
texture formats to `_SRGB` (M2).
