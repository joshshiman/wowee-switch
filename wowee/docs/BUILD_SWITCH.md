# Building WoWee for the Nintendo Switch

This tree is the WoWee client (via the WoWPS 2.12 console port) retargeted at
the Nintendo Switch with devkitPro. It runs the client natively: no streaming,
no PC client in an emulator.

## What renders it

Vulkan, through **Mesa NVK** ported to the Switch
([PalindromicBreadLoaf/nxvk](https://github.com/PalindromicBreadLoaf/nxvk)) -
the same shape as the PS4 port, which shipped its own Vulkan ICD over GNM. The
driver exposes Vulkan 1.4 with `VK_KHR_surface` + `VK_NN_vi_surface`, so
presentation goes through libnx's default `NWindow` and swapchain images scan
out zero-copy.

nvvk exports a single symbol (`vk_icdGetInstanceProcAddr`), so
`src/platform/switch/vk_nxvk_loader.cpp` forwards the plain Vulkan API into it.
The per-function trampolines in `vk_nxvk_loader.inc` are generated from the
Vulkan headers by `tools/switch/gen_nxvk_loader.py`.

## Prerequisites

* devkitPro with `devkitA64`, `libnx` and `portlibs/switch`
  (`switch-zlib`, `switch-pkg-config`):
  `sudo dkp-pacman -S switch-dev switch-zlib`
* the nxvk driver as a devkitPro portlib - it is built from Mesa in a
  container, so this needs podman or docker:
  ```
  tools/switch/fetch-nxvk.sh            # clones PalindromicBreadLoaf/nxvk
  # in that clone: make image && make && sudo make install
  ```
* `cmake >= 3.20`, `ninja`, `python3 >= 3.10`

Blizzard client data (MPQs, DBCs) is **not** in this repository. Copy your own
WotLK `Data` directory to `sdmc:/wowps/Data` on the console.

## Build

```sh
export DEVKITPRO=/opt/devkitpro        # or C:/devkitPro
tools/switch/build_switch_nro.sh --config Release
```

The build produces `build-switch/bin/wowee.nro` and stages an SD-card layout
under `out/switch/` (copy that to the SD card root, so the title ends up at
`sdmc:/switch/wowee/wowee.nro`). Launch it from your homebrew menu.

`tools/switch/build_switch_nro.sh --help` documents the options; the CMake
commands it wraps are:

```sh
cmake -S . -B build-switch -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=cmake/switch.toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release
cmake --build build-switch --parallel
```

## Runtime layout

| Path | Contents |
|------|----------|
| `romfs:/` (inside the .nro) | `assets/shaders/*.spv`, UI images, `Data/expansions`, `Data/opcodes` |
| `sdmc:/wowps/Data` | your own WotLK client `Data` (MPQs, locale subdirectories) |
| `sdmc:/wowps/assets/local_realm` | bundled local-realm data (copied at build time) |
| `sdmc:/wowps/wowps/` | writable tree: `logs/`, `cache/`, `saves/`, `config/`, `tmp/` |

`WOW_DATA_PATH` defaults to `sdmc:/wowps`; `WOWEE_LOG_LEVEL`, `WOWEE_RESOURCE_ROOT`
and the other `WOWEE_*` knobs work as on desktop.

## Platform layer

`src/platform/switch/` is the whole console layer (`platform::switchport`):

| File | Switch equivalent |
|------|-------------------|
| `system_switch.cpp` | `fsdevMountSdmc`, `appletInitialize`, `socketInitializeDefault`, boot log, fatal dialog, DNS via `getaddrinfo` |
| `input_switch.cpp` | libnx `hid` (Nepad + touchscreen) -> the client's emulated keyboard/mouse; the in-game on-screen keyboard modal |
| `audio_backend_switch.cpp` | miniaudio custom backend over `audout` (48 kHz stereo s16) |
| `threads_switch.cpp` | stack-size reporting; the audio context sets its own 2 MiB thread stack |
| `extract_switch.cpp` | first-launch MPQ extraction with logged progress |
| `cpu_geometry.cpp`, `cpu_memory.hpp` | page-aligned allocations and probe-based headroom inside the title heap |
| `vk_nxvk_loader.cpp` | Vulkan entry-point trampolines into nxvk |

The SDL-shaped event/keyboard layer the client code expects is kept as the
`include/platform/switch/sdl_scancode_compat.h` slice the PS4 port introduced,
now fed by HID instead of a DualShock 4.

## Known gaps

* No `deko3d`/GLES2 path: rendering is Vulkan 1.x through nxvk, which is what the
  renderer already spoke on the PS4.
* GPU timestamps stay uncalibrated (as on the PS4 port) until the nxvk backend
  contract is validated; `WOWEE_VK_DEFER_PRESENT` defaults to on.
* The depth-receipt / swapchain-storage debug probes that used the PS4 ICD's
  vendor extensions are compiled out (`WOWEE_PS4` only).
* Licensing: linking the statically-linked Mesa driver makes the binary a
  combined work under the GPL - ship the corresponding source with it. See
  `switch/third_party/nxvk/NOTICE.md`.

## Regenerating the loader trampolines

```sh
python tools/switch/gen_nxvk_loader.py \
    --headers references/nxvk/include/vulkan \
    --out src/platform/switch/vk_nxvk_loader.inc \
    vkCreateBuffer vkCreateDevice ...   # the directly-called entry points
```