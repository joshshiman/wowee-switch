# AGENTS.md — WoWee Switch

Working notes for anyone (human or agent) driving this project. Facts here were
verified against the live console on **2026-10-08**; anything that changes
(address, Atmosphere version, where logs land) should be updated here first.

## What this is

The WoWee WoW 3.3.5a client retargeted at a hacked Nintendo Switch: devkitA64 +
libnx, Mesa NVK as the Vulkan driver, runtime assets beside the `.nro`. Two
build trees: `build-host/` (Linux desktop, runs locally with `wowps/` data) and
`build-switch/` (the NRO).

Read these before changing anything:

| Doc | For |
|-----|-----|
| [README.md](README.md) | Installing, SD layout, controls, troubleshooting |
| [PORTING.md](PORTING.md) | How the port is put together, licensing |
| [wowee/docs/BUILD_SWITCH.md](wowee/docs/BUILD_SWITCH.md) | Toolchain, resource-root resolution, diagnosing a launch |
| [AUDIT_FIRST_RUN.md](AUDIT_FIRST_RUN.md) | Known first-run blockers — the to-do list |
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
| `/switch/wowee/wowee.nro` | the title (only file there today) |
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

**The log level is pinned to `WARNING` on a Release build** and cannot be
changed from the console, so an `INFO`-only detail is simply not there. Do not
read a quiet log as a healthy one. A hard crash (SIGSEGV, abort, data abort)
produces *nothing* in `boot.log` — it stops mid-line — and a report appears in
`/atmosphere/crash_reports/` instead, which is why step 4 fetches it.

## Traps, in the order they have bitten

- **Never overwrite a `.nro` while the title is running.** Close it from the
  Home menu first.
- **An embedded romfs beats `sdmc:/switch/wowee/data`.** `appRoot()` resolves
  `WOWEE_RESOURCE_ROOT` → `data/` beside the `.nro` → the `.nro`'s own
  directory → `sdmc:/switch/<name>/data` → **the romfs inside the `.nro`** →
  `sdmc:/switch/wowee/data`. Both current and card builds embed a romfs, so
  copying a shader or asset onto the card does *not* take effect — changing
  anything shipped as an asset means rebuilding and redeploying the whole
  `.nro`.
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

## State as of 2026-10-08

- `build-switch/` builds clean: 727/728 targets, `wowee.nro` 74 MiB, romfs
  patched in, 0 unresolved symbols. Commands in step 1 above.
- **The card is running an older build** (`.nro` dated 2026-10-06, built from a
  tree that predates the current MPQ/StormLib fixes). Do not compare a fresh
  log against it without deploying first.
- The last run on the console hangs in the asset phase: `boot.log` ends at
  `assets: storm lseek(fd=5, 0)` while opening `common.MPQ`, and the matching
  crash report is a data abort. The current tree contains commits aimed at
  exactly this (`304c9ab`, `54b16a1`, `bb527a2`, `1c070fe`), so the next
  iteration of the loop is: build → deploy → run → fetch.
- Nothing in [AUDIT_FIRST_RUN.md](AUDIT_FIRST_RUN.md) is out of date about
  hardware being unverified — it has since been run on hardware, and the
  blockers are still the reading order for whatever a new log shows.
