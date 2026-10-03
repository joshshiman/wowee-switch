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
  If you cannot build Mesa, drop a prebuilt release into
  `/opt/devkitpro/portlibs/switch` instead: `libvulkan.a` from the
  `nvk-switch-mesa-*` archive plus its matching `vk_video` headers.
  `cmake/switch/nxvk.cmake` detects both layouts.
* `cmake >= 3.20`, `ninja`, `python3 >= 3.10`

If `dkp-pacman` cannot reach the devkitPro servers (they return `403` from some
networks), the same toolchain can be unpacked from the published container image:

```
podman pull devkitpro/devkita64:latest
# copy /opt/devkitpro out of the image and point DEVKITPRO at it
```

Blizzard client data (MPQs, DBCs) is **not** in this repository. Copy your own
WotLK `Data` directory to `sdmc:/wowps/Data` on the console.

## Build

```sh
export DEVKITPRO=/opt/devkitpro        # or C:/devkitPro
tools/switch/build_switch_nro.sh --config Release
```

The build produces `build-switch/wowee.nro`, stages the runtime assets in
`build-switch/wowee-data/`, and `cmake --build build-switch --target switchpkg`
assembles an SD-card layout under `out/switch/` (copy that to the SD card root,
so the title ends up at `sdmc:/switch/wowee/wowee.nro` next to `sdmc:/switch/wowee/data/`).
Launch it from your homebrew menu.

`tools/switch/build_switch_nro.sh --help` documents the options; the CMake
commands it wraps are:

```sh
cmake -S . -B build-switch -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=cmake/switch.toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release
cmake --build build-switch --parallel
cmake --build build-switch --target switchpkg
```

## Runtime layout

| Path | Contents |
|------|----------|
| `sdmc:/switch/wowee/data` | `assets/shaders/*.spv`, UI images, `Data/expansions`, `Data/opcodes` (override the root with `WOWEE_RESOURCE_ROOT`) |
| `sdmc:/wowps/Data` | your own WotLK client `Data` (MPQs, locale subdirectories) |
| `sdmc:/wowps/assets/local_realm` | bundled local-realm data (copied at build time) |
| `sdmc:/wowps/wowps/` | writable tree: `logs/`, `cache/`, `saves/`, `config/`, `tmp/` |

The assets are staged beside the `.nro` instead of embedded in an NRO romfs:
this devkitPro `elf2nro` cannot read a romfs *directory* (it `mmap`s the
directory and fails), and a prebuilt image is appended without its `NroStart`
entry, so `romfsMountSelf()` would never find it either. A side-by-side
directory also means shaders can be refreshed by copying a file.

`appRoot()` looks for that directory in this order:

1. `WOWEE_RESOURCE_ROOT`
2. `data/` beside the `.nro`, then the `.nro`'s own directory (from `argv[0]`)
3. `sdmc:/switch/<nro name>/data` (launchers that pass a bare file name)
4. `sdmc:/switch/wowee/data`
5. a `<dir>/data` holding `assets/shaders`, found by listing `sdmc:/` and
   `sdmc:/switch` (step 5 exists because an emulator passes the `.nro`'s path
   on the *host*, which says nothing about the emulated card)

Rejected candidates are logged, so `logs/boot.log` records what was tried.

## Running under an emulator

NVK needs Horizon's memory model, which an emulator has to fake. Measured under
Eden 0.2.1 (Intel Arc A770, Vulkan 1.4.356), `vkGetPhysicalDeviceMemoryProperties`
reports **one heap containing one memory type, `flags=14 (0xe)` =
`HOST_VISIBLE | HOST_COHERENT | HOST_CACHED`, with no device-local type at
all** - guest VRAM is host memory there. (`HOST_CACHED` is `0x8` and
`LAZILY_ALLOCATED` is `0x10`; a `flags=0x` prefix followed by a decimal value
is a formatting trap worth avoiding in any log that gets read under pressure.)

The renderer copes with that: with no uncached host-visible type it uses the
device-local types when they exist, and otherwise leaves VMA's memory-type mask
unrestricted, which is what the attachment path in `vk_utils.cpp` does anyway.
Images are legal in host-visible memory and render correctly, without GPU
texture caching. `logs/wowps.log` records the whole memory table whenever the
preference cannot be met.

Known Eden caveat: allocating the first guest image crashed the emulator
outright, reproducibly - an access violation inside `eden.exe` (`0xc0000005` at
the same fault offset twice) during `nvhost` GPU setup, whether the type mask
named the host-visible type or was left unrestricted. Since Eden runs retail
titles that allocate images constantly, the trigger is something specific to
this allocation rather than image allocation in general; the shadow atlas is a
`D32_SFLOAT` depth image that is also sampled, which is the obvious suspect.

Eden nightly gets past that, boots the client and renders the first frame -
and then wedges: its shader recompiler rejects one Maxwell-only instruction
(`CreateGraphicsPipeline: Instruction IMAD32I is not implemented`) while NVK's
Maxwell output is what a real Switch GPU consumes natively, so this does not
apply to hardware. The recompile happens on a worker thread and the pipeline
call still returns success, so nothing is logged on the client side; the queue
then never completes, `vkQueuePresentKHR` blocks, and Windows reports the
emulator as not responding. `logs/boot.log` stops after
`gpu: frame submit complete`, and the per-frame breadcrumbs since
`main loop: frame N begin` name how far the frame got.

Two more caveats seen in that setup, neither of them a client bug:

* A launch can abort inside libnx before `main` when the loader's environment
  block carries no main-thread handle (see *Diagnosing a launch*). Fully
  exiting the emulator between runs clears it.
* An emulator's `sdmc:/` view can lag files copied in while it was running:
  assets that a probe reads fine may be invisible until it is restarted.

## Diagnosing a launch that does not get going

`sdmc:/wowps/wowps/logs/boot.log` is the only diagnostic channel: a homebrew
process's stdout is not surfaced by an emulator, and the fatal applet either
draws nothing or sits there as a spinner. It records the launch path, the
resource root that was chosen, every rejected candidate, and any startup stage
that failed. On an emulator, `sdmc:/` is the emulator's SD card folder - for
example `%AppData%\Eden\sdmc` - so the log is at
`%AppData%\Eden\sdmc\wowps\wowps\logs\boot.log`.

A launch that ends immediately with `Threw fatal error type 2` /
`LibnxError_ShouldNotHappen` is the resource check failing: copy
`build-switch/wowee-data` next to the `.nro` as `data/`.

An abort that happens *before* the client writes anything - nothing in
`boot.log`, and in the emulator's own log a jump to a near-null address with
`envSetup`/`envGetMainThreadHandle`/`__libnx_init` in the backtrace - is
libnx refusing to create the main thread because the loader's homebrew
environment block carries no `EntryType_MainThreadHandle`. Nothing in the
client runs at that point, so it is a property of how the title was launched,
not of the build. Seen under Eden after a previous launch had been force-stopped
while showing the fatal applet; fully exiting the emulator and launching again
cleared it, and setting the error applet to HLE avoids the state that led to it.
A minimal libnx program is a useful control: if that aborts too, the launch is
the problem rather than this client.

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

* Untested on hardware: the port compiles, links and packages, but no console is
  attached, so presentation, audio, HID and the login path have not been run.
* Blizzard Warden cannot run its native modules on Horizon: the kernel will not
  hand out anonymous RWX mappings, so `warden_module.cpp` loads the module
  read/write and refuses to call into it. Realms that issue a Warden challenge
  will not work; local and private servers do.
* `elf2nro` here cannot embed a romfs (see *Runtime layout*), so assets are read
  from the SD card rather than from the title itself.
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