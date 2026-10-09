# wowee-switch

The WoWee WoW 3.3.5a (WotLK) client, running natively on a hacked Nintendo Switch.

This file is for **playing the thing**. If you want to build it from source,
start at [GETTING_STARTED.md](GETTING_STARTED.md) — the verified Linux path,
end to end. The porting approach is in [PORTING.md](PORTING.md).

---

## Status: read this before you try it

**This build has never been run on a real console.** It compiles, links and
packages, but no Switch or Atmosphère was attached during development, so
display, audio, controller mapping and the login path are all unverified at
runtime.

A static audit of the code found six defects that will stop a first run. They are
listed in full, with file and line references, in
[AUDIT_FIRST_RUN.md](AUDIT_FIRST_RUN.md). **The short version:**

| # | What happens | Severity |
|---|--------------|----------|
| 1 | Audio plays about 20 ms of sound, then goes permanently silent. | blocker |
| 2 | Any graphics/audio setting you change before your first successful login is silently discarded — no error, no log. | blocker |
| 3 | Local-realm character saves are written to a PlayStation path that does not exist on a Switch, so saving fails. | blocker |
| 4 | If startup fails, the on-screen error is a bare code (`Threw fatal error type 2`). The message explaining what went wrong is thrown away. | blocker |
| 5 | The login connection sets a socket address field the Switch network stack may reject. Unverified — needs a console. | high |
| 6 | The title asks for a 1.5 GB heap, which may not be granted on a 2 GB console. | high |

There are also two things that will make the console experience poor even once
the above are fixed:

- **Suspending is not handled.** There is no applet hook, so the Home menu, the
  sleep button and docking/undocking are not responded to. A failed present is
  treated as permanent, so the most likely outcome is a black screen that never
  recovers. Force-close the title from the Home menu if this happens.
- **Closing from the Home menu does nothing.** The exit request is detected and
  then ignored.

So: **installing this today gets you a title that starts, and then a support
channel with nothing in it.** That is the honest state of it — the
[audit](AUDIT_FIRST_RUN.md) is the to-do list, in priority order.

### Servers

**You need your own server.** Blizzard's retail realms will not work: Warden
cannot execute its native modules on Horizon (the OS does not provide anonymous
RWX mappings), which rules out any realm that issues a Warden challenge. That
leaves private and local servers as the only realistic target — which is the
configuration this port was aimed at.

---

## What you need

- A hacked Switch (homedbrew-capable, with a recent Atmosphère and sigpatches).
- An SD card.
- **Your own copy** of a WotLK 3.3.5a client `Data` directory. Blizzard's game data
  is not included and cannot be. You need the `.MPQ` archives with their locale
  subdirectories intact.
- A server to connect to. See above.
- A built `wowee.nro` and its `data/` directory — either build it yourself
  ([GETTING_STARTED.md](GETTING_STARTED.md)) or get them from someone who has.

## Installing

Copy these to the SD card, keeping the layout exactly:

```
sdmc:/switch/wowee/wowee.nro      the title
sdmc:/switch/wowee/data/           assets and metadata (must travel with the .nro)
sdmc:/wowps/Data/                 your own WotLK client data
```

`switchpkg` stages the first two for you into `wowee/out/switch/switch/wowee/`;
copy that `wowee` folder to `sdmc:/switch/`.

Then open the homebrew menu and launch **WoWee**.

### If your game data is somewhere else

By default the client looks for `sdmc:/wowps/Data`. To change that, create a text
file at:

```
sdmc:/wowps/wowps/config/paths.cfg
```

containing a single line:

```
data_path=sdmc:/wotlk
```

Point it at either the folder that *contains* your `Data` directory, or the
`Data` directory itself — both are tried. Blank lines and `#` comments are
ignored.

This is the only thing you may need to set up by hand.

### How to find your logs

This is the only diagnostic channel the port has — a homebrew process's console
output is not visible on the Switch — so when something goes wrong, start here:

```
sdmc:/wowps/wowps/logs/boot.log     startup, one line per milestone
sdmc:/wowps/wowps/logs/wowps.log    the running client's log
```

Worth knowing: on a Release build the log level is pinned to `WARNING` and there
is currently no way to change it from the console, so most informational detail
is suppressed — including which asset archives were opened and which expansion
profile was chosen.

## Controls

One layer is active at a time, chosen by which shoulder you hold. Text fields
override all of it.

**On the pad**

| | |
|---|---|
| Left stick | Walk forward / back, strafe |
| Right stick | Mouse look (or move the cursor off the world screen) |
| ✕ | Left click / interact |
| ○ | Right click |
| □ | Action slot 1 |
| △ | Target nearest NPC or mob |
| D-pad ↑ / ↓ | Zoom in / out |
| D-pad ← / → | Turn left / right |
| L3 | Toggle autorun |
| R3 | Toggle cursor / mouse-look |
| − (minus) | World map |
| + (plus) | Game menu, close |

**Held modifiers** — the face buttons become a second, third and fourth row of
the action bar:

| Hold | Face buttons become |
|------|---------------------|
| R2 | slots 1–4 |
| L2 | slots 5–8 |
| R1 | slots 9–12 |
| L1 | character keys: ✕ jump / swim up, □ sit / stand, △ reset camera, ○ screenshot; D-pad walks |

**In a text field** (server address, realm name, character name, chat):

| | |
|---|---|
| △ | Open the on-screen keyboard |
| □ | Backspace |
| − (minus) | Send |
| R1 | Next field |
| D-pad | Move the caret, and walk chat history up / down |

To open chat in the world, hold **both index shoulders** (L1 and R1) at the same
time. That gesture is deliberately the only thing that claims it — everything
else is already spoken for. See the comment at
`wowee/include/platform/switch/input_switch.hpp` for the reasoning.

### Known control gaps

- **The touchscreen cannot click.** It moves the cursor and nothing else. Use the
  right stick and ✕ to press buttons; there is no tap-to-click and no multitouch.
- A **single** Joy-Con is not read. Handheld mode and a docked Pro Controller both
  work.
- If the on-screen keyboard opens and then the game leaves that screen without
  closing it, **all controller input stops** until you restart. If input dies,
  restart the title.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Nothing at all, or a brief flash | Check `logs/boot.log` first. A common cause is `data/` missing from beside the `.nro`. |
| `Threw fatal error type 2` | Any startup failure; the real message was discarded (blocker 4). Often the game `Data` directory not being found at `sdmc:/wowps/Data`. |
| Sound cuts out after a moment | Expected. See blocker 1. |
| Settings don't stick | Expected before first login. See blocker 2. |
| Black screen, title still running | A failed present is treated as permanent. Force-close from the Home menu. |
| Pad does nothing | Suspect the on-screen keyboard is stuck open, or that no controller was detected at boot. |

## Legal

Blizzard game data is not included, and this project is not affiliated with or
endorsed by Blizzard Entertainment.

Distributing a binary requires shipping the corresponding source: the client
statically links the Mesa NVK driver, which makes the result a combined work
under the GPL. See `wowee/switch/third_party/nxvk/NOTICE.md` and
[PORTING.md](PORTING.md#licensing).