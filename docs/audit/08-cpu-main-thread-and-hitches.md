# Audit 08 — CPU main-thread cost & frame-time spikes

Branch: `perf/switch-audit`. Domain: the main-thread CPU cost of a frame and the
transient hitches — the per-frame update path, terrain streaming/finalization on
the main thread, entity spawning/updates, the Lua VM and FrameXML addons, the
UI/widget system, input, and worker/thread usage. GPU fill/draw cost and the VMA
allocator are other audits (02–07, 09).

Method: static reading of the files below, **plus** the archived on-console
`[WORLD_PERF]`/stage-timing logs in `logs/console/archive/wowps.log`. Where a
conclusion uses a measurement, the log line is quoted. Where it is static, it is
marked. No hardware run was made.

Key files: `core/application.cpp`, `rendering/renderer.cpp`,
`rendering/terrain_manager.cpp`, `core/entity_spawner*.cpp`,
`addons/lua_engine.cpp`, `addons/addon_manager.cpp`, `ui/widget_tree.cpp`,
`ui/widget_renderer.cpp`, `ui/game_screen*.cpp`, `core/input.cpp`,
`platform/switch/threads_switch.cpp`, `include/core/thread_pool.hpp`.

---

## Headline

**The measured hitch is `Application::update` → `Renderer::update`, at 50–60 ms
per frame, not terrain streaming.** From the archived run (2026-10-10 03:25):

```
[WARN] SLOW update stage 'renderer->update': 51.02ms / 53.18 / 57.69 / 54.53 …   (a burst of ~14 in 3 s)
[WARN] SLOW update stage 'renderer->update': 242.20ms                            (one-off)
[WARN] frame budget over 10s: 64 frames, 6.40 fps, 156.3ms each
[WARN]   endFrame:          94.69ms/frame avg,  180.77ms worst, 60% of the window
[WARN]   addonWidgets:      17.59ms/frame avg,  982.44ms worst, 11% of the window
[WARN]   beginFrame:         9.48ms/frame avg,   56.97ms worst,  6% of the window
[WARN]   renderWorld:        4.70ms/frame avg,   34.53ms worst,  3% of the window
[WARN]   local authority/snapshots: 3.29ms/frame avg
[WARN]   local FrameXML update:     1.11ms/frame avg, 10.19ms worst
[WARN]   local entity loading:      0.41ms/frame avg, 24.41ms worst
[WARN]   local character sync:      0.38ms/frame avg
```

`updateMeanMs` for that 5 s window is **48.2 ms**, against `renderMeanMs` 154.6
and per-pass CPU means of ~1–5 ms each. So the CPU steady-state passes are small;
the spike is one update stage. `Renderer::update` sets `lastUpdateStage_` at
every step (`renderer.cpp:2140…2545`) but the slow path at
`application.cpp:4620-4622` logs only the total — **the name of the stage that
spent the 50 ms is recorded and then thrown away.** That is the single cheapest
change here and it unblocks every question below (W1).

The architecture is already unusually well optimised for this class of problem
(§ "What is already correct"). The remaining CPU work is therefore in four
places: (1) attribute the `renderer->update` spike, (2) the M2 spatial-index
rebuild that streams into that spike, (3) the `addonWidgets` 982 ms worst case,
and (4) per-frame allocation/map churn and Lua heap hygiene. Thread counting is
audit 11 § M1 and is not repeated here.

---

## Clear wins

### W1. Name the sub-stage in `SLOW update stage 'renderer->update'` — do this first
- Evidence: the logger at `application.cpp:4618-4622` reports `ruMs` only.
  `Renderer::update` already tracks `cameraMs` (`renderer.cpp:2155`) and
  `terrainMs` (`renderer.cpp:2316-2319`) and logs *their own* slow lines, but the
  budgeted sub-steps between them — the `m2AnimFuture.get()` join
  (`renderer.cpp:2460-2466`), `characterRenderer->update` (`:2444-2447`),
  `lightingManager->update` (`:2250`), `audioCoordinator_->updateZoneAudio`
  (`:2505`) and the every-2 s model cleanup (`:2516-2543`) — have no timer. The
  `SLOW` line cannot say which one it was.
- Change: wrap each of those in the existing `noteStageTime`-style timer and
  carry the slowest named sub-stage into the `SLOW update stage` line (or keep a
  `lastSlowUpdateStage_` string in `Renderer` set only when a sub-stage crosses
  ~40 ms, so the value survives to `Renderer::update`'s return). 10 lines.
- Impact: high (diagnostic; every remaining item is gated on it).
  Quality: certain. Risk: none. Quick win. **Switch-gate: no** (belongs on
  desktop too; the Switch already forces `frameProfileEnabled_`).

### W2. `noteStageTime` builds a `std::string` key on every call, every frame
- Evidence: `application.cpp:5662-5667` does `stageStats_[stage]` on
  `std::map<std::string, StageStat>` (`application.hpp:265`), and there are
  ~7 direct calls plus one per `runInGameStage` (`:4179`) and per `runRenderStage`
  (`:4732`) — a dozen-plus per frame. Names longer than 15 chars
  (`"gameHandler->update"`, `"local authority/snapshots"`,
  `"gameplay/transport queues"`, `"local FrameXML update"`) allocate.
- Change: index by a small enum (or intern the `const char*` once), keeping the
  same report text. Removes ~10 heap allocations/frame on the fragmentation-
  sensitive newlib heap.
- Impact: low-medium (per-frame churn, not a single-frame win). Quality: high.
  Risk: low. Quick win. **Switch-gate: no.**

### W3. `syncRenderInstancesToEntities` does a mutex + ~10 map lookups per creature per frame
- Evidence: `application.cpp:3661-…`, loop over `_creatureInstances`
  (`:3698`). Per creature it calls `getEntity()` — which takes a mutex **and
  copies a `shared_ptr`** (`game/entity.cpp:41-44`) — plus separate lookups into
  `_creatureRenderPosCache.find`, `_creatureFlyingState.count`,
  `_creatureSwimmingState.count`, `_creatureWalkingState.count`,
  `transportAttachmentsRef().count`, and `_creatureWasMoving/
  _WasSwimming/_WasFlying/_WasWalking[guid]` (the `operator[]` also inserts).
  With 112 NPCs (log: `npcs=112`, `m2Instances≈19000`) that is ~1200 ordered/
  unordered map ops + 112 mutex+refcount pairs per frame. The stealth pass
  (`entity_spawner.cpp:407-431`) already proves the cheaper pattern: use the
  unlocked `getEntities()` reference and `static_cast`.
- Change: one `struct CreatureFrameState { renderPos; wasMoving; wasSwimming;
  … }` keyed by guid, replacing the parallel maps; read the entity from
  `getEntities()` once. Medium refactor but mechanical.
- Impact: medium. Quality: medium. Risk: medium (touches creature visuals).
  Larger. **Switch-gate: no.**

### W4. `updateQuestMarkers` runs every frame, with a mutex lookup and a name scan per quest giver
- Evidence: `application.cpp:6114-6207` is called both from
  `updateInGame` (`:4398`) and the local path (`:4138`). It clears and rebuilds
  every marker each frame, calls `getEntity()` (mutex + `shared_ptr`) per
  status entry (`:6158`), and runs a hand-rolled case-insensitive
  substring scan for `"spirit healer"/"spirit guide"` over the NPC name
  (`:6169-6185`) on every one, every frame. NPC names never change.
- Change: cache the "is spirit healer/guide" result per guid (or per entry);
  read entities from `getEntities()` instead of `getEntity()`. The positions
  legitimately update per frame; the identity work does not.
- Impact: low-medium. Quality: high. Risk: low. Quick win (the predicate cache).
  **Switch-gate: no.**

### W5. Entity resync scan casts with RTTI where the type is already known
- Evidence: `application.cpp:4301-4383`, every 3 s: iterates **all** entities and
  does `std::dynamic_pointer_cast<game::Unit>` (`:4329`) after already testing
  `getType() == UNIT`. `syncCreatureStealthVisuals` uses `static_cast` for the
  same case (`entity_spawner.cpp:419-422`).
- Change: `static_cast`. Removes ~112 RTTI dynamic-casts per 3 s.
- Impact: low. Quality: high. Risk: none. Quick win. **Switch-gate: no.**

### W6. Minimap marker collection copies a `shared_ptr` per entity per frame
- Evidence: `ui/game_screen_minimap.cpp:1641-1654` iterates `getEntities()` and
  `push_back`s `shared_ptr` copies into `minimapUnits/Players/GameObjects`
  (atomic refcount churn), then eight category passes walk those lists. Same for
  the nameplate path (`ui/game_screen_hud.cpp:887-920`, reused `thread_local`s,
  but `getEntitiesNear` returns `shared_ptr` copies and sorts them).
- Change: collect raw `Entity*` for the life of the frame (main-thread only), or
  filter by category once. `minimapUnits` etc. are members and already reused, so
  only the refcount traffic changes.
- Impact: low-medium. Quality: medium (alias/lifetime care). Risk: low-medium.
  Quick-ish. **Switch-gate: no.**

---

## Measure first

### M1. `Renderer::update` spike = the M2 spatial-index rebuild joined onto the main thread
- Static mechanism: `Renderer::update` submits `m2Renderer->update(...)` to the
  frame pool (`renderer.cpp:2435-2438`) and then **blocks on
  `m2AnimFuture.get()`** at `:2460-2466` ("M2 animation completion").
  `M2Renderer::update` opens with `if (spatialIndexDirty_) rebuildSpatialIndex()`
  (`m2_renderer_render.cpp:326-328`). `spatialIndexDirty_` is set by **every
  model load** (`m2_renderer.cpp:2385`, "Map may have rehashed"). During
  streaming, models load continuously, so a full rebuild runs on many frames.
  `rebuildSpatialIndex` (`m2_renderer_instance.cpp:539-607`) clears and refills
  `instanceIndexById`, `instanceDedupMap_`, seven index lists, and `insertBounds`
  for **every** instance — `instances` is ~19 000 here.
- Why measure first: the log shows the 51–60 ms `renderer->update` arriving in a
  burst of ~14 frames over 3 s, right after a `TERRAIN_TILEHIST` dump — the
  signature of the streaming/load burst that repeatedly dirties the index. W1's
  timer will confirm the join is the cost before anything is touched.
- Candidate fixes (pick after W1):
  1. Make `models` rehash-stable (reserve, or a node-stable container / stable
     pointer index) so a model load no longer forces a *pointer refresh* rebuild.
  2. Rebuild incrementally (only instances of newly added/removed models).
  3. Coalesce rebuilds to ≤ a few Hz while streaming.
- Impact: high (this is the hitch). Quality: medium. Risk: medium (spatial index
  correctness underpins culling and collision). Larger. **Switch-gate: no**
  (the streaming pressure is heavier on Switch but the cost is general).

### M2. `addonWidgets` worst case was 982 ms; average 17.6 ms
- Evidence: log line above. This stage (`application.cpp:4840-…`, `runRenderStage(
  "addonWidgets")`) covers `widgetRenderer_.layout` (`:5413/5423`),
  `consumeDisplayChanges`, and the per-portrait offscreen model
  (`:5281-5399`). The 982 ms one-off is almost certainly a synchronous texture/
  portrait-model allocation, but nothing sub-times it.
- Action: add sub-stage timers (layout vs. portrait vs. display-change) inside
  the stage, same as W1. Portraits are already `visibleClaim`-gated
  (`:5291`) and FINDINGS says individually change-guarded — the win is knowing
  which of the three it is before touching any.
- Impact: medium (one-off hitches). Quality: high. Risk: none. Quick.
  **Switch-gate: no.**

### M3. Lua GC has no runtime step; the VM can only be reclaimed at load
- Evidence: `lua_gc(...)` appears only in the FrameXML loader
  (`addon_manager.cpp:900`, `:914`). The gameplay path relies on Lua's default
  incremental collector against a hard 64 MiB budget
  (`include/addons/lua_memory_budget.hpp:9`, `limit = 64 MiB`), and
  `collectgarbage` is removed from the sandbox (`lua_engine.cpp:5675`). The one
  unresolved crash is a mid-session Lua OOM raised in
  `SecureStateDriverManager OnUpdate` (AGENTS.md "still open").
- Action: add a bounded `lua_gc(L, LUA_GCSTEP, n)` per frame (or every N frames)
  on Switch, plus the existing `[WOWEE_MEM] lua_kb=` breadcrumb
  (`lua_engine.cpp:12115`) sampled steadily, and watch `luaKiB` and frame time.
  A step is far cheaper than a stop-the-world collect and spreads reclamation
  across frames.
- Impact: medium (stability more than fps). Quality: medium (needs tuning).
  Risk: low-medium. Measure first. **Switch-gate: yes.**

### M4. Layout/sizing gate is healthy in the sampled run — do not chase it
- Evidence: `[FX_GATE] laid out on 6 of the last 93 frames` and
  `fxLayoutSkipped=1` on 24/25 samples in the window; when it does break it costs
  `fxLayoutMs=6.43` with `fxSizingMs=5.18`. The gate is **not** the spike. (The
  `first=lua_engine.cpp:10638` attribution is line-drift from a build predating
  the current tree — no `markLayoutDirty` exists at that line today; re-check it
  against the exact deployed ELF if it recurs.)
- Action: none. Recorded so the "layout runs every frame" theory is not re-tried.
  If W1 shows layout inside the spike, revisit `sizeRegions`
  (`widget_renderer.cpp:1216`) — the sizing walk, not the solve, is the cost.

### M5. Worker/thread budget — see audit 11
- `thread_pool.hpp:82-90` sizes `frameWorkers()` to `hw-1` and `ioWorkers()` to 2
  on **all** platforms; `terrain_manager.cpp:115-118` hardcodes 2; the watchdog
  (`application.cpp:1380`), audio device, and world socket add more. On ~3
  Horizon cores that is the oversubscription audit 11 § M1 measured. Relevant
  *here* only because the M2 join (M1) can wait behind other pool tasks
  (`camera_controller.cpp:1002-1011`, `m2_renderer_render.cpp:653`, `:1317`).
  Not duplicated — act on audit 11's item.

---

## What is already correct (do not "fix")

These were checked and are genuinely done; listing them so they are not
re-attempted:

- **Terrain finalization is incremental and 4 ms-budgeted on the main thread.**
  `terrain_manager.cpp:2041-2097` yields between phase steps; a single
  `advanceFinalization` step is bounded (1 chunk / 1 model / 8 instances on
  Switch, `:1261`, `:1331`, `:1377-1378`). Decode, parse and mesh generation run
  on the 2 workers; the worker never touches the renderer (`:1858-1991`). The
  `SLOW terrainManager->update` line did **not** fire during the 50 ms burst —
  terrain is not the spike.
- **Entity spawning is 2 ms-budgeted per frame** and does file I/O + parsing on
  `std::async` workers: creature queue (`entity_spawner_processing.cpp:494-529`),
  async results with a 1-upload/tick GPU cap (`:46-60`), game-object queue
  (`:1237-1264`), WMO uploads stepping one group at a time.
- **The widget passes are list-driven, not tree sweeps**: `updateVisibility`
  (`lua_engine.cpp:10923`), `updateSizeChanges` (`:10739`),
  `updateScrollRanges`, and the `dispatchOnUpdate` pump all walk only the live
  part of the tree plus bounded change lists. `fxOnUpdateMs=0.88`,
  `fxOnUpdateCalls=13`, `fxVisVisits=441` in the sampled run — these are
  negligible.
- **Widget texture uploads are budgeted to 3/frame and discovery alternates idle
  frames** (`widget_renderer.cpp:2017-2065`); the draw is `drawOrder`-sorted once.
- **Input is O(64 keys) with no allocation** (`core/input.cpp:14-101`).
- **No `thread_local` is used on the hot CPU path** beyond the already-audited
  StormLib/parser sites (AGENTS.md, guarded by `verify_tls_access.py`).
- **`print()` goes to chat, not the log** — not a CPU cost, but the reason a
  "quiet log" is not evidence of a quiet frame here.

---

## Ranked shortlist

| # | Item | Impact | Risk | Effort | Switch-gate | Evidence |
|---|------|--------|------|--------|-------------|----------|
| 1 | Attribute the `renderer->update` spike (time the M2 join / char anim / lighting / zone-audio) | High (unblocks all) | None | Quick | No | `application.cpp:4618-4622`; `renderer.cpp:2435-2466, 2250, 2505` |
| 2 | Confirm & fix the M2 spatial-index rebuild on streaming (stable `models` / incremental / coalesced) | High | Medium | Larger | No | `m2_renderer_render.cpp:326-328`; `m2_renderer.cpp:2385`; `m2_renderer_instance.cpp:539-607`; log 51–60 ms bursts |
| 3 | Add per-frame Lua GC step on Switch + steady `lua_kb` telemetry | Medium (stability) | Low-Med | Quick | Yes | `addon_manager.cpp:900,914`; `lua_memory_budget.hpp:9` |
| 4 | Sub-time the `addonWidgets` stage (layout vs. portrait vs. display-change) | Medium | None | Quick | No | `application.cpp:4840-5424`; log `addonWidgets … 982.44ms worst` |
| 5 | Consolidate `syncRenderInstancesToEntities` maps + drop per-creature `getEntity()` mutex | Medium | Medium | Larger | No | `application.cpp:3661-…`; `entity.cpp:41-44`; `entity_spawner.cpp:407-431` |
| 6 | Cache the spirit-healer name predicate; use `getEntities()` in `updateQuestMarkers` | Low-Med | Low | Quick | No | `application.cpp:6114-6185` |
| 7 | Enum-key `noteStageTime` (drop per-frame `std::string` keys) | Low-Med | Low | Quick | No | `application.cpp:5662`; `application.hpp:265` |
| 8 | `static_cast` in the 3 s entity resync scan | Low | None | Quick | No | `application.cpp:4329` |
| 9 | Raw-pointer minimap/nameplate collection (drop `shared_ptr` copies per frame) | Low-Med | Low-Med | Quick-ish | No | `game_screen_minimap.cpp:1641-1654`; `game_screen_hud.cpp:887-920` |
| — | Worker count/affinity | — | — | — | — | audit 11 § M1 (not duplicated) |

Items 1, 3, 4, 6, 7, 8 are cheap and low-risk; item 1 should land first because
it converts every remaining item from a static guess into a measured one. Item 2
is the one likely to move the 50–60 ms hitch and should follow item 1's evidence,
not precede it.
