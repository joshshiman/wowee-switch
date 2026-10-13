# WoWee — World of Warcraft 3.3.5a on the Nintendo Switch

<p align="center">
  <img src="docs/wowee-hero.jpg" alt="WoWee on Nintendo Switch" width="640">
</p>

<p align="center">
  <img alt="Platform: Nintendo Switch (homebrew)" src="https://img.shields.io/badge/platform-Nintendo%20Switch%20(homebrew)-E60012">
  <img alt="Client: 3.3.5a (WotLK)" src="https://img.shields.io/badge/client-3.3.5a%20(WotLK)-1a7f37">
  <img alt="Renderer: Vulkan (NVK)" src="https://img.shields.io/badge/renderer-Vulkan%20(NVK)-8250df">
  <img alt="License: MIT + restriction" src="https://img.shields.io/badge/license-MIT%20%2B%20restriction-yellow">
</p>

<p align="center"><i>The World of Warcraft: Wrath of the Lich King (3.3.5a) client,
running natively on Nintendo Switch hardware — devkitA64 + libnx, Vulkan via
Mesa NVK, with a controller-native UI.</i></p>

WoWee is a **source port of the WoW 3.3.5a client to the Switch**. The game
logic, the interface (stock FrameXML + Lua 5.1) and the renderer all run
on-console, against **your own** WotLK game data. There is no emulation layer and
no streaming. No Blizzard code or game data lives in this repository — the
`.MPQ` archives stay yours, on your SD card.

It plays **offline** against a built-in local realm, or **online** against any
private server that doesn't issue a Warden challenge (this guide includes
standing up your own [AzerothCore](https://www.azerothcore.org/) server).

---

## Contents

- [Quick start](#quick-start)
- [What you need](#what-you-need)
- [1. Build the client](#1-build-the-client)
- [2. Put it on your Switch](#2-put-it-on-your-switch)
- [3. Run your own server (AzerothCore)](#3-run-your-own-server-azerothcore)
- [4. Connect the client to your server](#4-connect-the-client-to-your-server)
- [5. Controls](#5-controls)
- [6. Logs and troubleshooting](#6-logs-and-troubleshooting)
- [Project status](#project-status)
- [Contributing](#contributing) · [Credits](#acknowledgments) · [Legal](#legal)

---

## Quick start

There are two ways in. Both end at the same place: a Switch with WoWee on the
card, pointed at a server you control.

### Option A — hand it to an AI coding agent

If you use an agentic coding tool (Claude Code, Codex, OpenCode, Cursor, …) you
can have it do the whole setup. It needs three things from you up front, and it
will ask for the rest.

**Before you start, on the Switch:** install and run the
[`ftpd`](https://github.com/mtheall/ftpd) homebrew so the agent can copy files
over, and note the console's IP address (System Settings → Internet → your
network).

Then copy this into your agent:

```text
Set up "WoWee" for me: the World of Warcraft 3.3.5a client that runs on a
Nintendo Switch, plus a private AzerothCore server for it to connect to.

Repository: https://github.com/joshshiman/wowee-switch
README.md in that repo is the source of truth for paths, commands and gotchas.
Follow it closely; do not improvise where it is specific.

My host:    <your Linux distro, e.g. "Arch Linux, x86_64">
My Switch:  already hacked, Atmosphère installed, on my LAN at <SWITCH_IP>,
            with the ftpd homebrew running (anonymous FTP on port 5000)
Game data:  I have the WoW 3.3.5a client Data directory at <PATH_TO_Data>

Please, checking in with me before each big step:

1. Install the build toolchain: devkitPro with switch-dev and switch-zlib,
   plus cmake, ninja and python3, and the nxvk Vulkan driver
   (README "1. Build the client").
2. Configure, build and package the Switch client (README step 1).
3. Build AzerothCore, create and import the three databases, and set the realm
   to my LAN IP with gamebuild 12340 (README step 3). Set Warden.Enabled = 0.
4. Start authserver and worldserver, and create me an account with GM level 3.
5. Close WoWee on the Switch if it is running, then deploy the built client to
   it over FTP (README step 2), and verify the file landed by comparing md5.
6. Tell me exactly what to press on the Switch to log in and enter the world.

Rules: never write to my SD card outside sdmc:/switch/wowee/ and
sdmc:/wowps/wowps/. Ask me for the game-data path, my Switch IP, and any
passwords. If a build fails, read the log and fix the cause rather than
working around it.
```

### Option B — do it yourself

Five steps, each with its own section:

| # | Step | Section |
|---|------|---------|
| 1 | Build the client on your PC | [Build the client](#1-build-the-client) |
| 2 | Copy it to the Switch's SD card | [Put it on your Switch](#2-put-it-on-your-switch) |
| 3 | Stand up an AzerothCore server | [Run your own server](#3-run-your-own-server-azerothcore) |
| 4 | Point the client at it and log in | [Connect the client](#4-connect-the-client-to-your-server) |
| 5 | Play | [Controls](#5-controls) |

> [!NOTE]
> **Why you need your own server.** Blizzard's retail realms will not work.
> Warden (their anti-cheat) loads a native x86 module and calls into it, which
> needs an anonymous executable memory mapping — something the Switch's OS
> refuses to give a homebrew process. The client therefore can't answer a
> Warden challenge, and any realm that issues one will drop you. Private and
> local servers don't challenge, and are the supported configuration.

---

## What you need

| | Requirement |
|---|---|
| **Console** | A Switch able to run homebrew — Atmosphère (1.9.x verified) with sigpatches. |
| **Host PC** | Linux (verified on Arch/CachyOS). Also works for the host-only build on macOS/Windows, but the Switch build is the documented path. |
| **Toolchain** | devkitPro with `switch-dev` + `switch-zlib`, CMake ≥ 3.20, Ninja, Python ≥ 3.10. |
| **Vulkan driver** | The nxvk port of Mesa NVK for Switch — see [Install the toolchain](#install-the-toolchain). |
| **Game data** | Your own WoW **3.3.5a** `Data` directory (~15–17 GB, `.MPQ` archives with their locale subfolders). Not included, and cannot be. |
| **Server** | Anything reachable that doesn't challenge with Warden. Step 3 sets up your own. |
| **Disk** | ~2 GB for the toolchain and build, plus ~4 GB if you also run a server, plus the game data. |

---

## 1. Build the client

### Install the toolchain

Install devkitPro and the Switch packages, then the Vulkan driver.

```sh
# devkitPro (see https://devkitpro.org/wiki/Getting_Started for your distro)
sudo dkp-pacman -S switch-dev switch-zlib
```

`switch-dev` is a group (devkitA64 GCC, libnx, `elf2nro`, `build_romfs`, …).

The renderer needs **nxvk** — Mesa's NVK Vulkan driver ported to the Switch.
The easy path is the prebuilt drop-in (Mesa 25.0.7):

```sh
mkdir -p /tmp/nxvk && cd /tmp/nxvk
curl -fsSLO https://github.com/jhuz0/nvk-switch/releases/download/nvk-switch-mesa-25.0.7-r1/nvk-switch-25.0.7.tar.xz
curl -fsSLO https://github.com/jhuz0/nvk-switch/releases/download/nvk-switch-mesa-25.0.7-r1/libvulkan.a
tar xf nvk-switch-25.0.7.tar.xz

sudo install -d /opt/devkitpro/portlibs/switch/lib /opt/devkitpro/portlibs/switch/include/vulkan
sudo install -m644 lib/libvulkan.a               /opt/devkitpro/portlibs/switch/lib/
sudo install -m644 include/vulkan/*.h            /opt/devkitpro/portlibs/switch/include/vulkan/
sudo install -m644 NOTICE.md                     /opt/devkitpro/portlibs/switch/
```

> [!IMPORTANT]
> **The `vk_video` headers.** The driver archive's `vulkan_core.h` is header
> version 305 and includes `vk_video/…`, which the archive doesn't ship. Grab
> them from the matching Vulkan-Headers **tag** (not `main`):
>
> ```sh
> cd /tmp && git clone --filter=blob:none --no-checkout https://github.com/KhronosGroup/Vulkan-Headers.git
> cd Vulkan-Headers && git checkout v1.4.305 -- include/vk_video
> sudo install -d /opt/devkitpro/portlibs/switch/include/vk_video
> sudo install -m644 include/vk_video/*.h /opt/devkitpro/portlibs/switch/include/vk_video/
> ```

Set `DEVKITPRO` (`source /etc/profile.d/devkit-env.sh`, usually `/opt/devkitpro`)
and make sure `python3`, `cmake` and `ninja` are on your `PATH`.

### Configure and build

```sh
git clone https://github.com/joshshiman/wowee-switch.git
cd wowee-switch

export DEVKITPRO=/opt/devkitpro

DEVKITPRO=$DEVKITPRO cmake -S "$PWD/wowee" -B build-switch -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="$PWD/wowee/cmake/switch.toolchain.cmake" \
      -DCMAKE_BUILD_TYPE=Release

DEVKITPRO=$DEVKITPRO cmake --build build-switch --parallel "$(nproc)"
DEVKITPRO=$DEVKITPRO cmake --build build-switch --target switchpkg
```

A good configure prints:

```
-- Vulkan backend for Switch: nxvk (prebuilt) at /opt/devkitpro/portlibs/switch
-- WoWee: Nintendo Switch / libnx + devkitPro + nxvk
```

A full build takes ~4 minutes on 16 cores.

> [!WARNING]
> `-DCMAKE_TOOLCHAIN_FILE` **must be an absolute path**. A relative one fails
> at the first `project()` with "Could not find toolchain file".
>
> And if you change anything in `wowee/cmake/switch.toolchain.cmake` (compiler
> flags in particular), you must **reconfigure from scratch** — a flag change
> will not reach an existing `build-switch/` tree.

`switchpkg` stages everything you need to copy, at:

```
wowee/out/switch/switch/wowee/
├── wowee.nro      the title
├── wowee.elf      symbols (keep this with the build — you need it to read crash reports)
├── data/          runtime assets (shaders, expansions, opcodes, local-realm data)
└── addons/        the ConsolePort controller interface
```

---

## 2. Put it on your Switch

### SD card layout

Copy the staged `wowee` folder to `sdmc:/switch/` and add your game data:

```
sdmc:/switch/wowee/wowee.nro      the title
sdmc:/switch/wowee/data/          runtime assets — must travel with the .nro
sdmc:/switch/wowee/addons/        controller UI (ConsolePort)
sdmc:/wowps/Data/                 your own WoW 3.3.5a Data directory
sdmc:/wowps/wowps/                writable tree: logs, cache, saves, config, tmp
```

`sdmc:/wowps/wowps/` is created on first boot. If your game data lives somewhere
else, create `sdmc:/wowps/wowps/config/paths.cfg` with one line:

```
data_path=sdmc:/wotlk
```

(point it at the folder that contains `Data`, or at `Data` itself; blank lines
and `#` comments are ignored, and the first `data_path` wins).

> [!TIP]
> **Where assets actually come from.** The client resolves its resource root in
> this order, taking the first one that contains `assets/shaders/`:
>
> `WOWEE_RESOURCE_ROOT` → `data/` beside the `.nro` → the `.nro`'s own folder →
> `sdmc:/switch/<name>/data` → **the romfs embedded in the `.nro`** →
> `sdmc:/switch/wowee/data`.
>
> On a normal install the card's `data/` beside the `.nro` **wins** and the
> embedded romfs is only a fallback. `boot.log` records which one was chosen
> (`resource root: …`) and which were rejected (`not used: …`), so there is
> never any guessing.
>
> In practice: **code changes need a rebuild and redeploy.** Addon Lua is read
> straight off the card, so an edited `.lua` in `sdmc:/switch/wowee/addons/`
> takes effect on the next launch with no rebuild.

### Deploy over FTP

The title must be **closed first** — a running process holds its `.nro` open,
so writing over it fails or leaves a half-written file. With the `ftpd`
homebrew running (anonymous, port 5000):

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

Change the IP to your console's. A ~75 MB `.nro` takes about 20 seconds.

### Launch

From the homebrew menu, run **WoWee**. For full memory, use a **Title Override**
(hold **R** on any installed game and pick WoWee) rather than Album mode —
applet mode caps the process at ~450 MB.

Nothing prints to the screen; the diagnostic channel is
[`boot.log`](#6-logs-and-troubleshooting).

---

## 3. Run your own server (AzerothCore)

AzerothCore is the actively maintained 3.3.5a server. This section is the short
version; the [official install docs](https://www.azerothcore.org/wiki/installation)
cover the same ground.

### What the server needs

- Linux with a C++20 compiler, CMake, and Boost.
- **MySQL 8.0+** — recommended. (See [the MariaDB note](#a-note-on-mariadb) if
  you'd rather use MariaDB.)
- Your 3.3.5a client data, to extract `dbc`, `maps`, `vmaps` and `mmaps`
  (~3.2 GB once extracted).
- ~6 GB of disk and 8 GB of RAM to be comfortable.

### Build and install

```sh
git clone https://github.com/azerothcore/azerothcore-wotlk.git
cd azerothcore-wotlk
mkdir -p build && cd build

cmake .. -DCMAKE_INSTALL_PREFIX="$HOME/azeroth-server" \
         -DCMAKE_BUILD_TYPE=RelWithDebInfo \
         -DSCRIPTS=static -DMODULES=static
make -j"$(nproc)" && make install
```

### Create and import the databases

```sh
mysql -u root -p < ../data/sql/create/create_mysql.sql   # creates acore_auth/characters/world
cd "$HOME/azeroth-server/bin" && ./dbimport               # imports base + updates
```

### Extract the client data

Run the extractors from your 3.3.5a client folder so `dbc/`, `maps/`, `vmaps/`
and `mmaps/` land next to the server binaries (that's where `DataDir = "."`
looks).

### Configure

Copy `etc/authserver.conf.dist` and `etc/worldserver.conf.dist` to `.conf` and
check these keys:

| File | Key | Value |
|---|---|---|
| `worldserver.conf` | `Warden.Enabled` | **`0`** — required for this client |
| `worldserver.conf` | `Expansion` | `2` (WotLK) |
| `worldserver.conf` | `WorldServerPort` | `8085` |
| `worldserver.conf` | `DataDir` | `.` |
| `authserver.conf` | `RealmServerPort` | `3724` |
| `authserver.conf` | `StrictVersionCheck` | `0` |

Then set your realm's address — this is the address the **Switch** will connect
to, so it must be your server's **LAN IP**, never `127.0.0.1`:

```sql
UPDATE realmlist SET address = '192.168.2.38' WHERE id = 1;   -- your server's LAN IP
```

The row's `gamebuild` must be **12340** (3.3.5a), which is the default.

### Start it and create an account

```sh
cd "$HOME/azeroth-server/bin"
./authserver &     # listens on 3724
./worldserver &    # listens on 8085
```

At the worldserver's `AC>` prompt:

```
account create  yourname  yourpassword
account set gmlevel yourname 3 -1
```

### Open the ports

The console must be able to reach **TCP 3724** and **TCP 8085** on your server.
If the server host runs a firewall, allow both from your LAN:

```sh
sudo ufw allow from 192.168.2.0/24 to any port 3724 proto tcp
sudo ufw allow from 192.168.2.0/24 to any port 8085 proto tcp
```

<a id="a-note-on-mariadb"></a>
### A note on MariaDB

AzerothCore upstream supports **MySQL 8.0+ and dropped MariaDB in 2024**. On
MariaDB the server aborts at startup with `ACE00043` / "does not support MySQL
versions below 8.0" (MariaDB reports its own connector version, and the version
parser reads a two-digit major as one character). It's fixable — this project
ran on MariaDB 13 for a while with four small guards in `MySQLConnection.cpp`
and `DatabaseWorkerPool.cpp` — but **if you're starting fresh, use MySQL 8 and
skip that entirely.**

---

## 4. Connect the client to your server

### In-game

On the login screen choose the **External Realm** play mode, then **Advanced**:

| Field | Value |
|---|---|
| **Address** | your server's LAN IP, e.g. `192.168.2.38` |
| **Port** | `3724` (the auth port — not the world port) |
| **Expansion** | WotLK |

Enter your account name and password, log in, pick the realm from the list, and
enter the world. Your server settings are saved to
`sdmc:/wowps/wowps/.wowps/login.cfg`, so it's a one-time setup.

> [!NOTE]
> The client authenticates against the **auth** address you type, then connects
> to the **world** address your server advertises in its `realmlist` table —
> which is why that row has to hold a reachable LAN IP.

### Play offline instead

The login screen's **Single Player** mode drops you into a built-in local realm
— no server, no network. It's the fastest way to confirm the build works on your
console.

---

## 5. Controls

The in-world UI is a **controller-native action bar** (ConsolePort), not the PC
hotbars. Buttons are named by **position** — **X top, Y left, A right, B
bottom** — since letters differ between controllers.

On a server the world is aimed with a **screen-centre crosshair**: the cursor
rests in the middle of the screen and **A is the mouse's right-click**, so
walking up to something and pressing A interacts, loots or attacks it — no
targeting needed. Open a menu, the map, or press R3 and the crosshair steps
aside so the cursor behaves normally.

### On the pad — in the world (on a server)

| | |
|---|---|
| **A (right)** | **Right-click.** Attack / talk / loot whatever is under the crosshair; picks an item up in menus. |
| **Y (left)** | **Left-click.** Select or deselect; use/equip a bag slot. |
| **L1** | Target the nearest **attackable** thing and cycle through them on repeat (includes neutral mobs; skips quest givers and vendors). |
| **X (top)** | Jump. |
| **B (bottom)** | Cancel — stops casting and attacking and clears your target; closes menus; drops an item you're carrying. |
| **R1** | Bags. |
| **D-pad** | Extra action slots. |
| **ZL / ZR** | Shift / Ctrl tiers — each face button and bumper reaches more action slots. |
| **L3** | Toggle autorun. |
| **R3** | Hand the right stick back to the cursor (and A/B become left/right click). |
| **−** | World map, opening on the zone you're standing in. |
| **+** | The all-panels hub (character, spellbook, talents, map, quest log, bags, settings). |
| **L + R** | Chat. |
| **Left stick** | Move (forward/back, strafe). |
| **Right stick** | Camera. |

### On the pad — offline (local realm)

Same buttons, but a few differ because the offline world is driven by the
client itself: **L1** targets the nearest NPC and acts on it, **A** loots, and
**X** is jump-only.

### In menus

Any panel that opens — character, spellbook, quest log, bags, gossip, quest,
vendor, bank, trainer, auction, talents, mail, trade, loot, the game menu,
settings — is walked with the controller:

| | |
|---|---|
| **D-pad** | Move the focus (left/right adjusts a slider). |
| **X (top)** | Activate the focused control. |
| **A (right)** | Pick up / put down an item or spell; **confirms** in gossip, quest and loot windows. |
| **Y (left)** | Use / equip the focused bag slot. |
| **B (bottom)** | Close the panel. |
| **L1 / R1** | Scroll. |

The **world map** is the one panel driven by a pointer rather than a focus ring:
the right stick moves the cursor and **A** clicks the zone under it.

### Known control gaps

- The **touchscreen** moves the cursor but can't click.
- A **single Joy-Con** (sideways) isn't read — use both, or the Pro Controller.
- If the **on-screen keyboard** is left open, controller input stops until you
  restart the title.

---

## 6. Logs and troubleshooting

### Where the logs are

```
sdmc:/wowps/wowps/logs/boot.log     startup, one line per milestone — the diagnostic channel
sdmc:/wowps/wowps/logs/wowps.log    the running client's log
sdmc:/wowps/wowps/logs/chat.log     in-game chat
```

A homebrew process's stdout never reaches the screen, so **`boot.log` is how you
find out what happened.**

### Reading a run

1. **The verdict line.** The last line is usually
   `SELF-TEST: PASS  renderer=ok audio=ok hid=ok net=ok data=ok shaders=ok failed=none`.
2. **The last breadcrumb before it** names the stage that died
   (`window_initialize`, `renderer init: …`, `assets_prepare`, …).
3. **`resource root:` and `not used:`** show which asset root won and which were
   rejected.

> [!IMPORTANT]
> **A quiet log is not a healthy log.** On a Release build the log level is
> pinned to `WARNING` and can't be changed from the console, so `INFO` detail is
> simply absent. And a hard crash writes **nothing** — `boot.log` just stops
> mid-line — while a report appears in `/atmosphere/crash_reports/`.

### Common problems

| Symptom | What's happening | Fix |
|---|---|---|
| **Instant crash; `boot.log` just stops** | Almost always the `thread_local` miscompile, not a game bug. | Run `python3 wowee/tools/switch/verify_tls_access.py build-switch/wowee.elf`. If it fails, you changed the toolchain — restore `-ftls-model=local-exec` and reconfigure clean. |
| **`Threw fatal error type 2`** | A startup failure. | The real reason is in `boot.log`. Usually `data/` missing beside the `.nro`, or the game `Data` folder not found at `sdmc:/wowps/Data`. |
| **Black screen, title still running** | A failed frame present is treated as permanent. | Force-close from the Home menu and relaunch. |
| **Pad does nothing** | The on-screen keyboard is stuck open, or no controller was detected at boot. | Restart the title. |
| **An asset change had no effect** | The `.nro` embeds a romfs. | Rebuild and redeploy. (Addon Lua is the exception — it's read off the card.) |
| **Settings don't stick before you first log in** | A known bug — the config directory isn't created until after login. | Log in once, then change settings. |
| **"No NPCs" / an empty world, and a relog snaps you back** | A movement-acknowledgement bug that stops the server sending updates. | Fixed; if it recurs, pull `boot.log` and `wowps.log` and open an issue. |
| **A crash report naming only `hbmenu`** | Teardown noise, not the game. | Ignore it — a real report carries `wowee + 0x…` offsets. |

### Reading a crash report

Offsets only symbolize against **the exact `wowee.elf` that built the deployed
`.nro`**, so keep that ELF with the build:

```sh
ADDRS=$(grep -oP 'wowee \+ 0x\K[0-9a-f]+' crash_report.log | sort -u | tr '\n' ' ')
/opt/devkitpro/devkitA64/bin/aarch64-none-elf-addr2line -f -C -i \
    -e build-switch/wowee.elf $ADDRS
```

---

## Project status

**It runs on hardware, in-world.** The full boot path is live — romfs mount,
renderer init with every pipeline, all 18 MPQs opened (including the 2.9 GB
`common.MPQ`), FrameXML addons loaded — and the login screen, character creator
and world entry all work. Playable offline in the local realm and online against
a private server.

![Where the work is: a treemap of the port's remaining work](docs/port-progress.svg)

*Rectangle area is the work still remaining on that item, not what is built —
so the biggest blocks are what to do next. Regenerate it with
`python3 docs/make-port-progress.py` when a milestone lands.*

**Solid:** audio, the `thread_local` fix, the ImGui font-atlas crash, the
teardown crash, the controller-native UI (bar, hub, pad-navigable panels,
placing spells onto slots), and the crosshair world-control lane.

**Still rough:**

- **Settings saved before your first login are lost** — the config directory
  isn't created early enough.
- **Suspend/resume and docking aren't handled** — a failed present is permanent,
  so force-close. Closing from the Home menu is also ignored.
- **The heap request is far above the usual homebrew range** — a structural
  memory risk under long sessions.
- **A mid-session Lua out-of-memory crash** with no clean signature.
- Two user-facing error strings still mention a path from the PS4 port.

Full, honest, dated detail lives in [docs/FINDINGS.md](docs/FINDINGS.md) and
[AGENTS.md](AGENTS.md) — that's the ledger of what has been measured and what
has been ruled out.

---

## Contributing

The bottleneck is **hardware time**, not code review. The highest-value
contributions, in order:

1. **Console runs with logs.** Play on hardware, and when something breaks pull
   `boot.log` and `wowps.log` and attach them with what you were doing.
   `logs/console/` is git-ignored for exactly this — run artifacts can contain
   realmlist addresses and account names, so check before posting them publicly.
2. **Reproductions with teeth.** "I pressed A next to a wolf and it targeted the
   quest giver instead" beats a perfect theory.
3. **Code.** Open PRs against `main`; small, one-concern commits with log
   evidence beat large refactors. The Switch toolchain is only needed for
   hardware builds — the Linux host build covers most UI and systems work.

## Acknowledgments

This port stands on other projects' work, used with thanks:

- **[WoWee](https://github.com/Kelsidavis/WoWee)** — the 3.3.5a client this
  project derives from.
- **[WoWPS](https://github.com/01cedric/WoWPS)** — the console port (PS4) whose
  platform-layer split made this Switch retarget possible; see
  [PORTING.md](docs/PORTING.md) for what was kept and what was replaced.
- **WoWx** — a WoW Xbox port, now offline, that inspired attempting this at all.
- **[ConsolePortLK](https://github.com/leoaviana/ConsolePortLK)** — the 3.3.5a
  backport of ConsolePort whose controller UI, assets and bindings ship as this
  port's native in-game interface (see `wowee/addons/`).
- **[nxvk](https://github.com/PalindromicBreadLoaf/nxvk)** / **Mesa NVK** — the
  Vulkan driver, and `jhuz0/nvk-switch` for the prebuilt Switch build.

## Legal

Blizzard game data is not included and cannot be — bring your own 3.3.5a `Data`
directory. This project is not affiliated with or endorsed by Blizzard
Entertainment.

Distributing a binary requires shipping the corresponding source: the client
statically links the Mesa NVK driver, which makes the result a combined work
under the GPL. See `wowee/switch/third_party/nxvk/NOTICE.md` and
[PORTING.md](docs/PORTING.md#licensing).
