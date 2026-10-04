# Porting wowee to the Nintendo Switch

For **installing and playing**, see [README.md](README.md). For **what is broken**,
see [AUDIT_FIRST_RUN.md](AUDIT_FIRST_RUN.md).

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
tools/switch/build_switch_nro.sh    # -> build-switch/wowee.nro + wowee-data/
cmake --build build-switch --target switchpkg  # -> out/switch/switch/wowee/
```

The runtime assets are staged in `build-switch/wowee-data/` and shipped beside
the `.nro` (the homebrew reads them from `sdmc:/switch/wowee/data`, overridable
with `WOWEE_RESOURCE_ROOT`). They are not embedded in an NRO romfs because the
devkitPro `elf2nro` build here cannot read one.

Then copy your own WotLK `Data` directory to `sdmc:/wowps/Data` on the console.

> **Caveat, and read this before trusting a clean clone.** The three commands
> above are the intended flow, but the audit found the build will not complete
> from a fresh checkout as written: the scripts are committed non-executable, the
> NRO romfs patch is invoked through an unset CMake variable, and the driver's
> `libvulkan.a`/`vulkan.h` layout is unpinned. See the *"HIGH — build"* section
> and its *"Related build findings"* subsection in
> [AUDIT_FIRST_RUN.md](AUDIT_FIRST_RUN.md) for the fixes.

## Status

The port compiles, links and packages: `wowee.elf` and a 38 MB `wowee.nro` are
produced by devkitA64 GCC 15.2 with statically linked Mesa NVK, and
`cmake --build build-switch --target switchpkg` stages a complete SD-card tree.
The resulting ELF has no unresolved symbols, exports the driver's
`vk_icdGetInstanceProcAddr`, and keeps the generated loader's
`vkCreateInstance`/`vkCreateDevice` trampolines internal.

**Not yet run on hardware.** There is no console or Atmosphère here, so display,
audio, input, controller mapping and the WotLK login path are unverified at
runtime. Blizzard's Warden cannot execute its native modules on Horizon (no
anonymous RWX mappings), which rules out realms that issue Warden challenges;
private and local servers remain the working target.

### What has been verified, and what has not

Verified by reading the code together with the actual built artifacts
(`build-switch/wowee.elf`, Mesa 25.0.7) and the vendored libnx sources in
`references/`:

* The ICD loader contract. Every trampoline routes through
  `vk_icdGetInstanceProcAddr`, the `.inc`'s instance/device split matches NVK's
  single flat table, and the `.inc` is provably complete — a missing entry point
  would be a link error, and the ELF links.
* `VK_KHR_surface` + `VK_NN_vi_surface` enablement, `VK_KHR_swapchain` on the
  device, and `apiVersion` 1.1 against a 1.4 driver.
* `VkViSurfaceCreateInfoNN` is filled correctly for this nxvk, and
  `nwindowSetImageParameter` is genuinely *not* needed — nxvk owns the window.
* Every `VkSwapchainCreateInfoKHR` field against the driver's actual reported
  capabilities (format, colour space, usage flags, composite alpha, present mode).
* First-frame acquire/submit/present ordering, semaphore re-arming after a
  `vkDeviceWaitIdle`, and MSAA forced to 1x.
* HID init order and the `hidReady()` guard, which is mandatory because the HID
  reads `diagAbort` rather than return when the shared memory is unmapped.
* The audout parameters (48 kHz, 2 channels, Int16) and the fact that audio-init
  failure degrades silently rather than aborting.

Not verified, for want of a console: that the heap grant succeeds, socket
non-blocking semantics, the Switch network stack's tolerance of the connect
address, suspend/resume behaviour, and whether the build reproduces from a clean
clone.

No PS4 or SDL3 code is reachable on the Switch path — the `WOWEE_PS4` blocks are
nested inside `#ifdef WOWEE_SWITCH` and additionally guarded, so they compile to
nothing.

## Licensing

Blizzard data is not included, and this project is not affiliated with or
endorsed by Blizzard Entertainment. Linking the statically-linked Mesa driver
makes the resulting binary a combined work under the GPL: ship the
corresponding source with any binary you distribute (see
`wowee/switch/third_party/nxvk/NOTICE.md`).