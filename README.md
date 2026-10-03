# wowee-switch

The WoWee WoW 3.3.5a client, running natively on a hacked Nintendo Switch.

```
wowee/     the client (WoWPS 2.12 console port retargeted at the Switch)
docs/      (in wowee/docs) BUILD_SWITCH.md is the port's build + layout doc
```

## Approach

The Switch has no PS4 GNM/VideoOut path, and the plan that started this
(`WOWEE-SWITCH-PLAN.md`) assumed the renderer had to be rewritten for GLES2 or
deko3d. That assumption turned out to be obsolete:

* the console runs Mesa's **NVK** Vulkan driver, ported to Horizon by
  [PalindromicBreadLoaf/nxvk](https://github.com/PalindromicBreadLoaf/nxvk),
  with `VK_KHR_surface` + `VK_NN_vi_surface` for presentation over libnx's
  `NWindow`;
* WoWPS was already a *console* port of WoWee with the platform layer split out,
  the SDL event/keyboard slice emulated on top of a pad, the game logic
  untouched, and a vendored Vulkan ICD as the renderer backend.

So the port is the PS4 -> Switch substitution the plan's Phase 0-2 describe,
except the renderer swap became "point the existing Vulkan renderer at NVK"
instead of "rewrite it in GLES2":

| Piece | Switch implementation |
|-------|------------------------|
| Toolchain | `cmake/switch.toolchain.cmake` - devkitA64 + `switch.specs`, nacptool/elf2nro |
| Vulkan | `cmake/switch/nxvk.cmake` + `src/platform/switch/vk_nxvk_loader.cpp` (entry points forwarded into `vk_icdGetInstanceProcAddr`) |
| WSI | `VK_NN_vi_surface` over `nwindowGetDefault()`, surface-capability swapchain |
| System services | `src/platform/switch/system_switch.cpp` - libnx fs/socket/applet, `sdmc:/` paths, boot log, fatal dialog |
| Input | `src/platform/switch/input_switch.cpp` - libnx HID (Nepad + touchscreen) into the client's emulated keyboard/mouse; in-game on-screen keyboard |
| Audio | `src/platform/switch/audio_backend_switch.cpp` - miniaudio custom backend over libnx `audout` |
| Networking | newlib BSD sockets (`socketInitializeDefault`), `getaddrinfo` DNS, fcntl non-blocking |
| Packaging | `tools/switch/package.sh` - homebrew SD-card layout; no PKG |

## Build

See [wowee/docs/BUILD_SWITCH.md](wowee/docs/BUILD_SWITCH.md). Short version:

```sh
export DEVKITPRO=/opt/devkitpro
tools/switch/fetch-nxvk.sh          # builds/installs Mesa NVK as a portlib
tools/switch/build_switch_nro.sh     # -> build-switch/bin/wowee.nro + out/switch/
```

Then copy your own WotLK `Data` directory to `sdmc:/wowps/Data` on the console.

## Status

Ported and wired end to end, but **not yet compiled on hardware**: this machine
has no devkitPro install, so the work so far is source-level (plus a generated
Vulkan loader verified against the real headers). The first build on a machine
with `devkitA64` is where link-time surprises will surface - most likely the
nvvk archives' link order, and the exact libnx entry points this port settled on
from the headers.

Blizzard data is not included, and this project is not affiliated with or
endorsed by Blizzard Entertainment. Linking the statically-linked Mesa driver
makes the resulting binary a combined work under the GPL: ship the
corresponding source with any binary you distribute (see
`wowee/switch/third_party/nxvk/NOTICE.md`).