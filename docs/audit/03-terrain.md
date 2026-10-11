# Audit 03 — Terrain rendering & streaming

Scope: terrain mesh generation, chunk draws, mega vertex/index buffers, terrain
alpha/layer textures, ground clutter, terrain frustum/distance culling, tile
residency budget, per-frame terrain cost and streaming hitching.
Read-only; observations from `perf/switch-audit`. Nothing here was run on the
console — every claim is code + the FINDINGS ledger.

## How the path runs (facts verified in code)

- Terrain CPU recording runs on a worker into a secondary command buffer
  (`renderer.cpp:3224-3241`), executed after sky and before WMO. Grass rides in
  the *same* secondary (`renderer.cpp:3234-3236`).
- Geometry: 145 verts/chunk (9×17 interleaved layout, **4 triangles per quad**
  around a centre vertex — inherent to WoW MCVT, not a bug), 768 indices/chunk,
  256 chunks/tile = **37,120 verts + 196,608 indices per tile**
  (`terrain_mesh.cpp:186-328`).
- Vertex format is 44 B: 3+3+2+2 floats + a trailing `uint8_t chunkIndex`
  (`terrain_mesh.hpp:16-29`). `chunkIndex` is **never written**
  (`generateVertices` never sets it, `terrain_mesh.cpp:220-264`) and **never
  read** (`terrain.vert.glsl:20-23` declares only 4 attributes). It is dead
  padding — the header comment at `terrain_vertex.hpp:17-18` says the 44 stride
  is "what the trailing `chunkIndex` byte pads out to".
- Indices are `uint32_t` (`terrain_mesh.hpp:34`; bound `VK_INDEX_TYPE_UINT32`
  at `terrain_renderer.cpp:1095,1158`), for a 145-vertex mesh.
- Mega VB/IB hold all chunks and are drawn with per-chunk `vkCmdDrawIndexed`
  base offsets (`terrain_renderer.cpp:1088-1176`). Switch sizing:
  `MEGA_VB_MAX_VERTS = 128k` (≈5.6 MB), `MEGA_IB_MAX_INDICES = 1M` (4 MB)
  (`terrain_renderer.hpp:315-316`). Per-chunk VB/IB are the fallback
  (`terrain_renderer.cpp:724-737`).
- `uploadChunk` writes into mega and only falls back when mega is full
  (`terrain_renderer.cpp:706-737`). **`removeTile` never rolls `megaVBUsed_`
  back** — only `clear()`/`shutdown()` reset it (`terrain_renderer.cpp:1398-1415`
  vs `1471-1473`). Mega is therefore a **one-shot**: at 37,120 verts/tile it is
  exhausted after ~3.5 tiles and the remaining ~7 resident tiles take per-chunk
  buffers for the rest of the session. FINDINGS run 59 confirms the leak shape
  ("megaUsed=130935 counts the leaked reservations").
- Every chunk gets its **own params UBO** (`TerrainParamsUBO`, 4 ints) via a
  dedicated VMA allocation (`terrain_renderer.cpp:663-691`, called at `:462`)
  and its own material descriptor set (`:470`, `MAX_MATERIAL_SETS = 4096 = 16
  tiles` on Switch, `terrain_renderer.hpp:254`).
- Main pass binds set 1 + draws **once per chunk** (`terrain_renderer.cpp:1145-1170`);
  the shadow pass uses gathered `vkCmdDrawIndexedIndirect` (`:1367-1388`), the
  main pass does not.
- Streaming: `loadRadius = 1`, `unloadRadius = 2`, `kMaxResidentTiles = 10`
  (`switch_world_budget.hpp:11-13`); only **one** decoded payload is admitted at
  a time on Switch (`terrain_manager.cpp:1916`); in-world chunk upload is
  **1 chunk/step** (`terrain_manager.cpp:1260-1264`) inside a **4 ms** frame
  budget (`terrain_manager.cpp:2043,2117`) — the taxi 8/16 ms branch is
  `#else`-only, so Switch always uses 4 ms.
- Ground clutter (detail M2 doodads) cap is 880/tile × density scale
  (`terrain_manager.cpp:2757-2763`); default clutter 15 → scale 0.15 →
  ≈132 instances/tile (`graphics_defaults.hpp:23`, `settings_panel.cpp:1175-1176`).
  These are full M2 instances and land in `m2Draws`.
- Grass is GPU-culled with atomic compaction and an indirect draw
  (`grass_renderer.cpp:538-659,754-775`), default **off** on Switch
  (`renderer.cpp:974`, `savedSetting("grass_enabled", 0.0f)`).

## Clear wins (mechanical, low risk, do without a console run)

### T1 — The mega buffers are a one-shot; reclaim them — HIGH (memory/stability), MED (draw state)
`removeTile` (`terrain_renderer.cpp:1398-1415`) frees the chunk records but does
not decrement `megaVBUsed_`/`megaIBUsed_`; only `clear()` does (`1471-1473`).
Mega holds ~3.5 tiles (VB-bound), the resident cap is 10 (`switch_world_budget.hpp:13`).
So after the first three tiles finalize, **every subsequent tile takes the
per-chunk fallback**: 2 buffers × 256 chunks = 512 VMA allocations per tile
(`terrain_renderer.cpp:726-736`), plus a per-chunk VB/IB rebind in the draw
(`:1165-1167`). This is the exact fragmentation pattern that produced the run-45
VMA crash, and it wastes the design intent of the mega buffers.
Options, easiest first:
1. **Two (or three) mega buffer pairs** instead of one: 6.7 MB each keeps every
   single allocation under the 9.6 MiB NVK cap and covers ~7 tiles (3 per pair
   VB-bound). Small, localized change to init + `uploadChunk` + bind.
2. **Per-tile mega regions + free list + rollback on `removeTile`**, compacting
   only on a frame where `uploadsIdle()` (the existing deferred-destroy model
   already tolerates reuse after frame fences). Correct but more work.
Quality risk: low (identical geometry, only buffer identity changes). Switch
gate: the whole mega path is already Switch-sized; make the change Switch-only
(`#ifdef WOWEE_SWITCH`) so desktop keeps its 1.5 M-vertex buffer.

### T2 — Delete the dead `chunkIndex` byte: 44 B → 40 B per vertex — MEDIUM
Field never written or read (see facts above). Removing it takes the stride to
40 B (−9 % VB bytes and VB fetch bandwidth) and lifts mega VB tile coverage from
~3.5 to ~3.9 tiles. Quick, no visual change. Because
`kTerrainVertexAttributes` is built from `offsetof` (`terrain_vertex.hpp:22-27`)
only the struct changes. Switch gate: none (both trees shrink), but the mega
constants already differ per platform so it self-scales.

### T3 — `uint32_t` → `uint16_t` terrain indices — MEDIUM
145 vertices/chunk fits a 16-bit index with room to spare, and the draw already
uses a per-chunk `vertexOffset` (baseVertex), so indices stay local to the chunk
(`terrain_renderer.cpp:1161-1162`). Change `TerrainIndex` (`terrain_mesh.hpp:34`)
and the two `VK_INDEX_TYPE_UINT32` binds (`:1095,1158`; shadow `:1353,1374`) to
`UINT16`. Halves IB footprint and index fetch bandwidth and doubles mega IB tile
coverage (5.3 → 10.7 tiles, no longer the binding constraint). Risk: low
(must keep the mesh < 65,536 verts, which it is by construction). Quick.

### T4 — Drop the per-chunk params UBO for a push constant — MEDIUM/HIGH (hitches)
`createChunkParamsUBO` allocates a 16-byte VMA buffer **per chunk** (256/tile)
and `writeMaterialDescriptors` writes it into set 1 (`terrain_renderer.cpp:663-691,
998-1019`, member `terrain_renderer.hpp:47-49`). The four ints could ride in a
push constant (16 B; the model matrix is 64 B, total 80 < 128-byte floor) and
binding 7 be deleted, leaving a 7-sampler set. This removes 256 VMA allocations,
256 descriptor UBO writes, and one descriptor entry per chunk **per tile** — a
direct cut to the streaming finalize cost and to VMA churn. Quality risk: low;
the trade is that `terrain.frag.spv` is no longer byte-identical (a stated goal
of the packed-alpha change, `terrain_renderer.hpp:56-63`). Switch gate: apply
behind `#ifdef WOWEE_SWITCH` or take it for both (desktop benefits too).

### T5 — Ground-clutter budget and a clutter-specific view cut — MEDIUM
The tile cap is 880 × 0.15 ≈ 132 M2 instances/tile (`terrain_manager.cpp:2757-2763`),
drawn by M2Renderer and counted in `m2Draws`, the single largest cost bucket in
run 60 (+122 ms from 135→257 draws). Clutter is small screen geometry that only
matters near the player. Lower `kBaseMaxGroundClutterPerTile` (e.g. to ~480) and/or
give clutter a shorter draw distance than general doodads. Quality risk: thinner
ground cover; screenshot-compare. Switch gate: `#ifdef WOWEE_SWITCH`.

### T6 — Let the Switch taxi/streaming budget breathe — LOW/MEDIUM
`processReadyTiles`/`processPendingUnloads` hard-code 4 ms on Switch; the 8/16 ms
`taxiStreamingMode_` branch is `#else`-only (`terrain_manager.cpp:2043,2117`).
A long taxi flight therefore drains at the same 4 ms as an idle walk and can fall
behind real churn (the comment at `terrain_manager.hpp:635-654` describes exactly
this snowball). Allowing 8–16 ms in `taxiStreamingMode_` on Switch is a
one-line-per-site change. Verify with the existing `SLOW terrain update`
breakdown (`terrain_manager.cpp:244-248`).

## Measure first (plausible but unverified / may change visuals)

### M1 — Four-triangle-per-quad / LOD / skirts: probably not worth it — LOW
Terrain is a CPU-cheap, fill-covered pass: run 60's quartile analysis shows
terrain draw count contributing **−16 ms (noise)** (`FINDINGS` run 60), and
`terrainMs ≈ 0` in every WORLD_PERF (`application.cpp:2110`). Vertex/triangle
count reduction (LOD, skirts) targets vertex work, but the frame is
fragment/draw-count bound. Crack-free LOD would add seam risk for little gain.
Only revisit if a per-pass GPU timing split ever becomes available (it does not —
`gpuTimingStatus=uncalibrated-switch`, `application.cpp:2074`).

### M2 — Move grass population generation off the main thread — MEDIUM (only when grass on)
Grass is off by default, but when enabled `updateGrassPopulation` runs on the
main thread every frame (`renderer.cpp:1555-1558`), rebuilds whenever the player
moves 24 yards (`:2814`), and samples **64,000 lattice cells per frame**
(`:3078`) — each a `findChunkAt`/`evaluateGrass`. During travel this is a
near-continuous main-thread cost and a strong hitch candidate. Fix: move the
builder to a worker, or drop `kCellsPerSlice`. Switch gate: none. Measure with
grass enabled + a `SLOW`/`updateMeanMs` sample.

### M3 — Terrain fragment shader: local lights + derivative bump are unconditional — LOW/MEDIUM (fill)
`localLightContribution` loops the nearest ≤8 lights per fragment
(`terrain.frag.glsl:155-172`, cap `switch_world_budget.hpp:34`), and the
derivative normal-map "bump" runs for every fragment within 125 yards
regardless of the `normalMapping` setting (`terrain.frag.glsl:236-251`). Ground
covers most pixels, so this is near-worst-case fill; interiors/cities amplify the
light loop. Fix: gate the bump behind the existing normal-mapping CVar and/or a
smaller terrain-only light cap. Risk: flatter near ground; screenshot-compare.
Terrain is cheap, so treat as fill-bound follow-up, not a priority.

### M4 — Terrain main pass has no indirect path — LARGER
The shadow pass batches mega chunks through `vkCmdDrawIndexedIndirect`
(`terrain_renderer.cpp:1367-1388`); the main pass does one bind + draw per chunk
(`:1145-1170`). But material **descriptor sets differ per chunk** (different
alpha masks/layers), so indirect alone will not remove the per-chunk set binds —
the real win would be bindless sampling (one big texture array indexed by push
constant). That is a large, risky redesign on NVK; park it. (Note: this is also
why "one draw per tile" is not achievable cheaply — each chunk's alpha differs.)

### M5 — Serialized streaming: one payload, 1 chunk/step — MEDIUM, needs a decision
Only one decoded tile payload is admitted at a time (`terrain_manager.cpp:1916`)
and in-world upload advances **1 chunk per step** (`:1260-1264`). At the measured
2–3 ms/chunk that is ~130–256 frames to stream one tile — during travel the
ground arrives very late. Raising the payload limit needs headroom (the current
limit exists for the 2 GB flexible heap); lowering per-tile cost via T1/T4 is the
safer lever. Decide with one travel sample that has the `TERRAIN_CHUNKS`/`SLOW
terrain update` lines.

### M6 — Debug instruments still cost per-frame CPU — LOW (cleanup)
The Switch `nearestSurvey_` insertion sort runs over **every** chunk every frame
(`terrain_renderer.cpp:1104-1120`) and `TERRAIN_TILEHIST` builds bins over all
chunks every 60 frames (`:1177-1223`). Small, but they are round-64 scaffolding
(AGENTS.md "temporary instruments") and should come out with the rest.

## Explicitly NOT a terrain cost on Switch

- **Terrain shadow pass is free.** Switch forces `shadowQuality = 0`
  (FINDINGS run 49; `renderer.cpp` setting sinks), so `renderTerrain`'s shadow
  path is not exercised. Do not optimize `renderShadow` for perf.
- **Alpha textures are already packed.** Three masks share one RGBA image with
  swizzled views (`terrain_renderer.cpp:599-660`; `createAlphaTexture` reuse
  cache `terrain_alpha_cache.hpp`). Image count is not the terrain problem.
- **Material descriptor pool is not exhausted.** 4096 slots = 16 tiles ≥ the
  10-tile resident cap; no fallout like the WMO pool (FINDINGS run 46).
- **`chunkHasHoles`/`getHeightAt` and collision are CPU-side** and don't touch
  the GPU frame.

## Ranked shortlist

1. **T2** remove the dead `chunkIndex` byte (zero risk, 9 % VB cut) — do first.
2. **T3** 16-bit terrain indices (low risk, halves IB, doubles mega IB room).
3. **T1** reclaim/expand the mega buffers (fixes the one-shot fallback; the
   largest structural win for memory + draw state).
4. **T4** params UB O → push constant (kills 256 VMA allocs/tile → shorter
   finalize steps, less churn).
5. **T5** clutter cap / clutter view cut (direct cut to the top cost bucket).
6. **T6** taxi-aware 8–16 ms budget on Switch (one-liners; helps long travel).
7. **M2** grass generation off the main thread (only when grass is enabled).
8. **M5-measure** one travel sample to size the streaming-budget question.
9. **M3** gate the terrain bump / trim terrain local lights (fill follow-up).
10. **M6** remove `TERRAIN_DIAG`/`nearestSurvey`/`TILEHIST` scaffolding.
11. **M4 / M1** bindless main pass, terrain LOD — larger, unclear payoff; park.
