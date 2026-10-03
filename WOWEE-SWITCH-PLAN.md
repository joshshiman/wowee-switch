# WoWee / WoWPS on a Modded Nintendo Switch — Port Plan

Date: 2026-10-02

## Target goal

Run a native C++ WoW 3.3.5a client on a hacked Nintendo Switch:

- world + character + combat + chat + quest + inventory using a real local/remote server (`AzerothCore` etc.)
- no cloud streaming
- no running the original Windows client in an emulator

## What to reuse

Use two existing projects as bases:

1. `WoWee` — the C++ WoW client core:
   - protocol, SRP6, world/character/quest/combat logic, FrameXML/Lua parsing, asset loading, audio logic.
2. `WoWPS` — the closed but full-source PS4 adaptation:
   - shows how to take WoWee's C++ core and console-target it.
   - already adapted SDL2, filesystem, sockets, controller mapping, logging, VPK packaging flow.

`WoWPS` is MIT with a commercial-game restriction; it is the right *porting model*, not source to ship as-is.

## The renderer problem

Neither `WoWee`'s current master nor `WoWPS` will run on a stock modded Switch without GPU-layer changes.

Current state:

- `WoWee` is now Vulkan/SDL3.
- `WoWPS` uses Vulkan 1.0 over GNM/VideoOut on PS4.

Switch has no existing Vulkan driver at the level WoWee/WoWPS assumes.

So the renderer must move from:

- PS4: Vulkan 1.0 over GNM/VideoOut
- Switch variants:
  - `vitaGL`-style wrapper over `sceGxm` аналог, for Switch: `deko3d` + GLES2, or
  - an `OpenGL ES 2.0 / GLSL ES` shim such as SDL2 + gl4es-style translation, or
  - a custom narrow low-level GXM대신 GLES2 renderer you author specifically.

This is the main porting project.

## Recommended implementation order

### Phase 0 — decide the exact renderer backend

Fork/read `WoWPS` first. Its `ps4/` tree already has the console split:

- `ps4/compat/`
- `ps4/third_party/ps4_vulkan/`
- `cmake/ps4.toolchain.cmake`
- `tools/ps4/`

For Switch, create the same shape:

- `switch/`
  - `compat/`
  - `third_party/`
  - `deko3d or gles2 glue`
- `cmake/switch.toolchain.cmake`
- `tools/switch/`

`WoWPS` + PS4 Vulkan is *not* directly portable, but `WoWee + SDL2/OpenGL`-era code from before the current Vulkan migration may be closer to what Switch needs.

### Phase 1 — get a console-core build

Port WoWee/WoWPS logic through Atmosphere homebrew first, graphics off or stubbed:

- filesystem: `/data` paths → Switch SD/NAND paths
- networking: Berkeley sockets already mostly portable; add HostN3DS-style socket init if needed
- audio: use Switch's SDL2 audio or a miniaudio backend
- controller mapping: Switch pad layout
- no framebuffer dependency yet

result: program starts, connects, logs in, receives world packets, but renders to a dummy buffer.

### Phase 2 — minimal GLES2 player

Replace the Vulkan renderer with a narrow GLES2/deko3d one:

- terrain
- sky/day/night
- water/fog
- simple character/NPCs
- UI/canvas stub forFrameXML initially

This part is where most effort goes. It decides whether the Switch port is actually viable.

### Phase 3 — FrameXML/Lua and gameplay

Then revive the original UI layers:

- chat, quest tracker, minimap
- inventory, vendors, spells, action bar
- party/UI panels

At this point the port is usable.

### Phase 4 — audio, streaming, performance

- music, ambient, combat SFX through Switch audio
- asset streaming/packaging optimizations
- save data layout

## What to clone / reuse

`WoWee`:
- game/protocol core stays
- `assets` manifest / `Data/` layout, M2/WMO/ADT/BLP pipeline

`WoWPS`:
- console CMake wiring
- OpenSSL11 compat shim
- controller docs
- packaging concept

New work:
- replace PS4-specific filesystem, controller, sockets, logging paths with Switch ones
- replace the graphics backend, because current Vulkan won’t map cleanly
- provide Switch SDL2/GLES2 video driver and toolchain file

## Key risks

- **Renderer rewrite dominates effort**, not Wi-Fi or packet code.
- Vita-specific drivers don’t transfer; Switch does not run `PVR_PSP2` or PS4's GNM/Vulkan.
- `WoWPS` is source-available but closed-font-of-assets and license-restricted for commercial games.
- A full WoW 3.3.5a renderer on Switch means aggressive optimization:
  - 720p-ish target
  - fewer materials / simpler post-processing
  - no Vulkan-only effects (ray tracing, HDR, FSR)

## Answer to your practical question

Yes, a modded Switch is a better target than a Vita for that game:

- stronger CPU/GPU
- SDL2/homebrew ecosystem more mature for OpenGL/ES
- existing C++ games move more naturally than they would to a PowerVR-era stack

But it is still not a straight `WoWee` or `WoWPS` port: you still need to swap the **renderer** from Vulkan to the Switch's usable GL/deko3d path.

The fastest usable prototype is:

1. take `WoWPS`'s *console port scaffolding*,
2. target WoWee's game logic,
3. stub rendering initially,
4. add a minimal GLES2 terrain/character renderer,
5. only then worry about FrameXML and polish.
