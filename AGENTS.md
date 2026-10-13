# AGENTS.md — WoWee Switch

Working notes for anyone (human or agent) driving this project. Facts here were
verified against the live console on **2026-10-13**; anything that changes
(address, Atmosphere version, where logs land) should be updated here first.

**Read [docs/FINDINGS.md](docs/FINDINGS.md) before debugging anything.** It is
the ledger of what has been measured, what has been ruled out, and which fixes
exist and why — written so a measurement is never repeated and a ruled-out
theory is never re-tried.

## What this is

The WoWee WoW 3.3.5a client retargeted at a hacked Nintendo Switch: devkitA64 +
libnx, Mesa NVK as the Vulkan driver, runtime assets beside the `.nro`. Two
build trees: `build-host/` (Linux desktop, runs locally with `wowps/` data) and
`build-switch/` (the NRO).

Read these before changing anything:

| Doc | For |
|-----|-----|
| [README.md](README.md) | Installing, SD layout, controls, troubleshooting |
| [PORTING.md](docs/PORTING.md) | How the port is put together, licensing |
| [wowee/docs/BUILD_SWITCH.md](wowee/docs/BUILD_SWITCH.md) | Toolchain, resource-root resolution, diagnosing a launch |
| [AUDIT_FIRST_RUN.md](docs/AUDIT_FIRST_RUN.md) | Known first-run blockers — the to-do list |
| [docs/audit/00-MASTER-REPORT.md](docs/audit/00-MASTER-REPORT.md) | Handheld performance audit: ranked levers for rendering/graphics/memory (branch `perf/switch-audit`) |
| [WORKSPACE.md](WORKSPACE.md) | Local-only notes on this checkout (git-ignored) |

## The console loop

There is a real Switch on the LAN and the whole hardware side of the project
runs in this cycle:

```
build locally → FTP the new .nro to the card → close & relaunch the title
→ reproduce on the pad → FTP the logs back → read, fix, repeat
```

**Console: `192.168.2.44`, FTP port 5000, anonymous login.** The server is the
mtheall `ftpd` homebrew (`/switch/ftpd/ftpd.nro`), *not* sys-ftpd, and it only
serves while it is running. Atmosphere 1.9.x. This host has no `lftp` or
`curlftpfs`, so everything below goes through `python3`'s `ftplib` — verified
working, passive mode, ~3.8 MiB/s up, so a 74 MiB `.nro` takes about 20 s.

### 1. Build

```sh
DEVKITPRO=/opt/devkitpro cmake --build build-switch --parallel "$(nproc)"
DEVKITPRO=/opt/devkitpro cmake --build build-switch --target switchpkg
```

`switchpkg` stages the SD tree at `wowee/out/switch/switch/wowee/`
(`wowee.nro`, `wowee.elf`, `data/`, `addons/`). If `build-switch/` does not
exist yet, the full configure is in WORKSPACE.md — note
`-DCMAKE_TOOLCHAIN_FILE=` **must be an absolute path**.

### 2. Deploy

Push the staged tree to `sdmc:/switch/wowee/`. **Close the title first**: a
running process holds its `.nro` open, so writing over it fails or leaves a
half-written file.

```sh
python3 - <<'PY'
import ftplib, pathlib
SRC = pathlib.Path("wowee/out/switch/switch/wowee")
DST = "/switch/wowee"
f = ftplib.FTP(); f.connect("192.168.2.44", 5000, timeout=30); f.login(); f.set_pasv(True)
def mkdir(p):
    try: f.mkd(p)
    except ftplib.error_perm: pass
for p in sorted(SRC.rglob("*")):
    rel = p.relative_to(SRC).as_posix()
    if p.is_dir(): mkdir(f"{DST}/{rel}")
    else:
        with open(p, "rb") as fh: f.storbinary(f"STOR {DST}/{rel}", fh)
        print(f"  {rel}  {p.stat().st_size/2**20:.1f} MiB")
f.quit()
PY
```

### 3. Run

Launch **WoWee** from the homebrew menu. Nothing prints to screen — see
*Reading a run*.

### 4. Fetch the logs

```sh
RUN=logs/console/$(date +%Y-%m-%d_%H%M)
python3 - "$RUN" <<'PY'
import ftplib, pathlib, sys
OUT = pathlib.Path(sys.argv[1]); OUT.mkdir(parents=True, exist_ok=True)
f = ftplib.FTP(); f.connect("192.168.2.44", 5000, timeout=30); f.login()
for remote, local in [("/wowps/wowps/logs/boot.log", "boot.log"),
                      ("/wowps/wowps/logs/wowps.log", "wowps.log")]:
    with open(OUT / local, "wb") as fh: f.retrbinary(f"RETR {remote}", fh.write)
    print(f"{remote} -> {OUT/local} ({(OUT/local).stat().st_size} bytes)")
names = [n for n in f.nlst("/atmosphere/crash_reports") if n.endswith(".log")]
if names:
    newest = sorted(names)[-1]
    with open(OUT / "crash_report.log", "wb") as fh:
        f.retrbinary(f"RETR {newest}", fh.write)
    print(f"{newest} -> {OUT/'crash_report.log'}")
f.quit()
PY
```

`logs/console/` is git-ignored on purpose — console logs are run artifacts and
can contain realmlist addresses and account names.

## What is on the card

| Path | What |
|------|------|
| `/switch/wowee/wowee.nro` | the title (`Data/` + `assets/` are baked into its romfs; addons are not) |
| `/switch/wowee/addons/` | ConsolePort set — read straight off the card, so a Lua-only FTP push works (see traps) |
| `/wowps/Data` | the 17 GB WotLK client data, `enUS/` included — never re-deploy |
| `/wowps/wowps/logs/` | `boot.log` (startup breadcrumbs), `wowps.log` (client log), `chat.log` |
| `/wowps/wowps/{cache,saves,config,tmp}` | writable tree; `config/paths.cfg` overrides the data root |
| `/atmosphere/crash_reports/` | crash `.log` + `dumps/*_thread_info.bin` per crash |
| `/atmosphere/fatal_reports/` | fatal reports + `dumps/` |
| `/atmosphere/logs/` | AMS's own logs (`dns_mitm_startup.log`) |

## Reading a run

**`boot.log` is the only diagnostic channel.** A homebrew process's stdout is
never surfaced, so if a run went badly the answer is in this file, not on the
screen. Read it in this order:

1. `tail -1 logs/console/<run>/boot.log` — the `SELF-TEST: PASS|FAIL
   renderer=… audio=… hid=… net=… data=… shaders=… failed=…` verdict line. One
   line, greppable, and it is the contract: never change its field order.
2. The last `[timestamp]` breadcrumb line before the verdict names the stage
   that died (`window_initialize`, `renderer init: <thing>`, `assets_prepare`,
   …).
3. A `resource root: …` line with `not used:` lines under it records which
   candidate paths were tried and rejected.
4. `wowps.log` fills in the detail behind a failed stage, and the fatal block
   (reason, expected path, how to fix) is written into `boot.log` verbatim.

**An unexplained instant crash is usually the TLS miscompile, not a game bug.**
`boot.log` simply *stops* — no fatal line, no verdict — and a report turns up
in `/atmosphere/crash_reports/` that would otherwise be confused with the
fatal reports in `fatal_reports/`. Symbolize it against the ELF that built the
deployed `.nro` (see the traps above):

```sh
ADDRS=$(grep -oP 'wowee \+ 0x\K[0-9a-f]+' crash_report.log | sort -u | tr '\n' ' ')
/opt/devkitpro/devkitA64/bin/aarch64-none-elf-addr2line -f -C -i -e build-switch/wowee.elf $ADDRS
```

If the fault address in the report is exactly twice the crashing register, it
is `ldr w0, [x0, x0]`. Run `tools/switch/verify_tls_access.py` next.

**The log level is pinned to `WARNING` on a Release build** and cannot be
changed from the console, so an `INFO`-only detail is simply not there. Do not
read a quiet log as a healthy one. A hard crash (SIGSEGV, abort, data abort)
produces *nothing* in `boot.log` — it stops mid-line — and a report appears in
`/atmosphere/crash_reports/` instead, which is why step 4 fetches it.

## Traps, in the order they have bitten

- **`thread_local` is miscompiled without `-ftls-model=local-exec`.** With
  `-mtp=soft` + `-fPIE`, devkitA64 g++ 16.1.0 emits `ldr w0, [x0, x0]` -
  base *and* index the thread pointer, so the load reads `2 × TP`, which is
  unmapped, and carries no relocation the linker could fix up. **423 sites in
  this client** (17 `thread_local` declarations across the renderer, HUD,
  minimap, packet parsers and StormLib's `dwLastError`) silently became data
  aborts. Symptom: the title aborts *instantly* on hardware while building,
  packaging and running perfectly on the host - the host build does not use
  these flags. StormLib's `SFileOpenArchive` calls `SErrGetLastError` on a
  failed syscall, so it always dies in the asset phase. The fix is in
  `cmake/switch.toolchain.cmake`.
- **Guard against it:** `python3 tools/switch/verify_tls_access.py
  <elf>` fails the build if the miscompiled shape reappears (it looks for a
  self-indexed load fed by `__aarch64_read_tp`). Run it on anything the console
  reports as an unexplained instant crash.
- **`nvk_AllocateMemory` does not bounds-check its memory type index.** ImGui's
  font atlas asks for `VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT` on the image path
  (but checks for failure on the buffer path), and this console has no
  device-local type, so it handed the driver `0xFFFFFFFF` and took a data abort
  at `base + (-1 << 3) + 6296`. Any new code asking for device-local memory
  needs the same host-visible fallback `rendering/vk_utils.cpp` and
  `imgui_impl_vulkan.cpp` now carry.
- **Never overwrite a `.nro` while the title is running.** Close it from the
  Home menu first.
- **The card's `data/` is authoritative; the romfs is only a fallback.**
  `appRoot()` resolves `WOWEE_RESOURCE_ROOT` → `data/` beside the `.nro` →
  the `.nro`'s own directory → `sdmc:/switch/<name>/data` → **the romfs inside
  the `.nro`** → `sdmc:/switch/wowee/data`, and the first candidate that has
  `assets/shaders/` wins. On the normal SD layout (`sdmc:/switch/wowee/wowee.nro`
  with a `data/` beside it) that is `sdmc:/switch/wowee/data`, so a shader or
  asset pushed onto the card **does** take effect. The romfs takes over only if
  the card's `data/` is missing or has no shaders — which is what the Oct 5–6
  "romfs wins" note actually measured. The newest console run logs
  `resource root: sdmc:/switch/wowee/data` with `not used: romfs:/` (see
  `logs/console/2026-10-12_1153_acworld/boot.log`), so the card wins in practice.
- **Addon Lua is read straight off the card, so a Lua-only FTP push works.**
  The romfs contains only `Data/` and `assets/` — **never `addons/`**.
  `switchpkg` stages `addons/` *beside* the `.nro` (and into `data/addons`),
  after the romfs is built. At runtime `AddonManager` scans
  `sdmc:/switch/wowee/addons` first and reads each Lua/XML file with a plain
  file read (`InterfaceSource` only special-cases `mpq/`-prefixed paths). So
  editing a file under `wowee/addons/` and FTPing **only that file** to the card
  takes effect on the next launch — no rebuild. The earlier "proven void"
  rounds were almost certainly SavedVariables shadowing the changed default or
  a `print()` probe (which goes to chat, not the log), not a romfs override.
  Code changes still need a rebuild and redeploy, and archived `Blizzard_*`
  addons still come out of the MPQs.
- **A crash report's `wowee + 0x…` offsets only symbolize against the exact
  ELF that built that `.nro`.** Resolve them with
  `/opt/devkitpro/devkitA64/bin/aarch64-none-elf-addr2line -f -C -e
  <the-elf-that-was-deployed>`. If you deploy from a tree you have changed
  since, keep a copy of that build's `wowee.elf` next to the record of the run,
  or the backtrace is misleading rather than wrong.
- **`/wowps/Data` is ~17 GB.** Its MPQs are also huge (`common.MPQ` alone is
  2.9 GB) and their hash/block tables are what the console budget is spent on —
  never push it, and never assume a "could not open the archive" error is a
  data problem before checking the budget lines in `boot.log`.
- Anonymous FTP will happily let you overwrite the client data or the card's
  Atmosphere files. Push only into `sdmc:/switch/wowee/` and
  `sdmc:/wowps/wowps/`.
- **SavedVariables shadow code defaults.** Per-character binding sets and bar
  setups persist on the card, so a changed default never reaches an existing
  character. Every handheld default ships with a one-shot in-place migration
  (`woweeBindRev` / `woweeRev` stamps in `Init.lua` / `Bar.lua`) — bump the
  stamp when changing a default.
- **Override buckets merge by owner-pointer order.** Key→command overrides
  live per owner and merge ascending, so a later-allocated frame's bucket
  silently wins collisions (this ate F1–F4 mid-session via the bar's
  `SetBindingClick`). Same-owner rewrites are the only deterministic move.
- **`print()` goes to chat, not the log.** Release logs sit at WARNING, so Lua
  diagnostics must use `__WoweeWarn`. A whole probe round was once lost to
  chat spam.
- **A crash report naming only `hbmenu`/`nx-hbmenu` with User Break is
  teardown noise**, not the game — it names no `wowee + 0x…` offsets and
  cannot be symbolized. Only reports carrying game offsets are actionable.
- **Scripted `Click()` never drives secure state.** `mt:Click` runs insecure
  scripts only; secure show/hide, clicks, and drag-drop are inert until the
  secure layer lands. Anything depending on them needs an insecure mirror or
  it reads as dead.
- **Frame alpha does not cascade to children** (each widget draws at its own
  alpha), while visibility does. An `alpha=0` frame with art children renders
  anyway — hide the frame instead.
- **Every game-handler method used from pad dispatch must check
  `localServiceRealm()` first** (`castSpell` pattern). The direct methods are
  remote-only and go nowhere offline — this exact gap killed an entire round
  of A-button work.
- **Temporary `[WOWEE_*]` instruments** (`PAD`, `KEYTRACE`, `ACT`, `OVR`,
  `MENU`, `MEM`, `ATTRDIAG`, `GLYPH`, center-band scan) are debug-round
  scaffolding, not features. Grep for them before adding another, and remove
  the set before calling the branch done. (`ACDBG` has been removed.)
- **Permanent instrumentation** (leave it): `[WOWEE_FACTION]` (a one-shot map
  summary plus a bounded per-unit line), `[WOWEE_TGT]` (guid/hostile/ft/mode/
  dist/name), `[WOWEE_LOOT]` (LootSlot + autostore + the LootFrame shown/rect
  proof), `[FX_GATE]` (the layout gate's dirty site — now unmasked, so it names
  the real caller), and the `[WORLD_PERF]` update-phase fields: `ghSocketMs
  ghPacketMs ghTimersMs ghInterpMs ghTransportMs ghTransportMgrMs
  ghTransportChildrenMs ghMiscMs pendingInbound pendingUpdateBatches
  blocksApplied packetsHandled outOfRangeRemoved ghTransports ghAttachedChildren
  ghTransportPushes ghWmoIndexRebuilds ghWmoIndexRefiles ghWmoTransformUpdates`.

## State as of 2026-10-13

- `main` carries the handheld perf work through Phase 6 (`perf/switch-audit`
  fast-forwarded onto it). `feature/consoleport-native-ui` is a literal ancestor
  of `main` — fully contained, nothing to reconcile; left in place, not deleted.
- UI/controls work lives on **`perf/switch-headroom`** (this checkout,
  `../wowee-switch-ui`).
- `build-switch/` builds clean and stages to `wowee/out/switch/switch/wowee/`
  (clean configure + ~4 min; incremental much less). Commands in step 1 above.
  **A flag change needs a clean configure** - `CMAKE_CXX_FLAGS_INIT` only
  applies to a fresh build tree, so editing the toolchain and rebuilding an
  existing `build-switch/` silently keeps the old flags.
- **The port is in-world on hardware with a controller-native UI.** Full boot
  path is live (romfs mount, resource-root resolution, renderer init with
  every pipeline, all 18 MPQs opened including the 2.9 GB `common.MPQ`,
  FrameXML addons loaded), and the login screen, character creator, and world
  entry all run. Playable offline in the local realm as well as on servers.
- **In-game UI is ConsolePort** (baked in as the native interface, Switch
  profile): face-button clusters with ZL/ZR modifier tiers, **Minus = world
  map, Plus = the all-panels hub** (the radial utility ring is retired). The
  live map is in [README.md](README.md#controls) — that table is verified
  against traces, treat it as the contract.
- **Three input layers are live at once** (base pad table is gated off; the
  local-realm UI reads the raw pad; ConsolePort drives F-keys): X = local
  action + jump, Y = auto-attack, A = interact/loot/attack + mouse, B =
  cancel, L = target + act, R = bags. Fixes go through the right layer —
  never silence one blindly. Details in `docs/FINDINGS.md` (operator overrule
  + double-drive record).
- **Crosshair lane (remote realm, in world, no menu open).** `Application::render`
  calls `setCrosshairActive(true)` (`application.cpp:4928`): the cursor is
  pinned to screen centre **at rest only** — not during a camera look, because a
  look is a right-button drag and the client tells a drag from a click by cursor
  travel, so holding the cursor still would fire a click on every turn. A is
  then the world's **right-click** (`game_screen.cpp:1969-2174`), Y the
  **left-click**, and L1 asks for a target (`tabTarget(..., includeNeutrals=true)`
  — cycles the nearest ATTACKABLE unit: hostile, or a neutral creature with no
  NPC flags). The reticle is not drawn. Any menu, the world map, or R3 cursor
  mode turns it all off and restores the ConsolePort meanings.
- **Audio is fixed** (blocker 1). `devWrite` no longer pre-waits on its own
  in-flight flag: libnx's `audoutPlayBuffer` already blocks until the hardware
  consumes the buffer and harvests the release.
- **`thread_local` was miscompiled and is now fixed.** 423 access sites compiled
  to `ldr w0, [x0, x0]`. Fixed with `-ftls-model=local-exec`, guarded by
  `tools/switch/verify_tls_access.py`.
- **The ImGui font atlas crashed on an unsatisfiable memory type**, now fixed.
- **The teardown crash is fixed.** `main()` uses `_Exit`, so `exit()` never walks
  the C library's open FILE list - one of which was in a bad state and aborted
  at 0x18 after `shutdown` had already been logged.
- Audit blockers: **2** (the pre-login config path) is still open; **3**
  (local-realm saves) is fixed in code, but two user-facing strings still print
  `/data/wow_ps/Data`; **4** is mitigated — the reason is now in `boot.log`,
  though the on-screen dialog is still a bare code; **5** (the login socket) is
  fixed; **6** is reduced to a 1280 MiB heap request, still above the usual
  homebrew range.
- Console memory is still the structural risk: the driver refuses allocations
  the heap reports it can serve (a 512x256 image fails at ~96 MiB live while
  256x128 serves right after), so `createBuffer`/`createImage` drain completed
  upload batches and retry once. VMA block sizes land as a fallback ladder
  (32, 16, 8, 4 MiB); `preferredLargeHeapBlockSize` stays 32 MiB (8 MiB broke
  M2 transfers).
- **This session landed:** the crosshair world-control lane (above); the
  connected-realm update cost (transport `pushTransform` rebuilt the WMO spatial
  index on every push — fixed; `updateMeanMs` 71-90 → ~10, `loopFps` 7.2 → 9.6);
  the idle FrameXML layout gate (`PlayerFrame`'s per-frame `SetAlpha` now
  repairs draw order directly; `fxLayoutSkipped=1` idle); loot (the addon guard
  no longer zero-sizes FrameXML's `LootFrame`, and the lane follows
  `LOOT_SLOT_CLEARED`); and the vendor error-sound spam (one bag pass +
  pending-GUID guard) and vendor item loading (query gate + prefetch).
- Controller panel access is landed: the utility ring is retired, **Minus =
  world map** and **Plus = the client's own all-panels hub**
  (`__WoweeToggleMenus` → `Application::toggleMenuHub`), the bar's show/hide
  button opens the same hub, and the native FrameXML pad lane (D-pad focus,
  Cross pick-up/put-down, Y use/equip in bags) runs under ConsolePort so the
  hub's panels are wire-walkable and spells/items can be placed onto action
  slots. Still open: a mid-session Lua-heap OOM crash with no clean signature
  match (new variant under investigation, `lua_kb` breadcrumb in place).
- **Character creation, login, world load and in-game rendering are all
  exercised regularly now.** The largest remaining unknown is sustained
  in-world stability (memory over long sessions), not reaching the world.
