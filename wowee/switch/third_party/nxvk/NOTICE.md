# nxvk (Mesa NVK Vulkan driver for the Nintendo Switch)

WoWee renders through Mesa's **NVK** Vulkan driver ported to the Switch:
<https://github.com/PalindromicBreadLoaf/nxvk>. The driver itself is not
vendored here - it is consumed as a devkitPro portlib:

```
git clone https://github.com/PalindromicBreadLoaf/nxvk
cd nxvk && make image && make && sudo make install   # needs podman/docker
```

which drops `lib/libnvk.a`, `lib/libnvk_support.a`, `include/vulkan/` and
`lib/pkgconfig/nxvk.pc` into `$DEVKITPRO/portlibs/switch`. `cmake/switch/nxvk.cmake`
then consumes it through pkg-config.

## What lives in this directory

`nvk_compat.c` - link-time gap fills the driver expects from the title it is
linked into. Taken from the port's own reference implementation
(`switch/smoke/nvk_compat.c`), with two additions for this client:

* `__nx_applet_type` / `__nx_heap_size`, which a title linking `libnvk.a`
  statically must define itself. The heap is sized for terrain/M2/WMO
  uploads plus the asset cache.

These are newlib/Horizon gaps, not NVIDIA code: `getrandom`, `posix_memalign`,
`sysconf`, `get*id`, `regcomp`/`regexec`/`regfree`, `pthread_sigmask`, `flock`,
plus stubs for disk-cache-only APIs. Upstream keeps them under
GPL-2.0-or-later; the SPDX header is preserved.

## Licensing

Mesa and the nxvk port keep their upstream licences (MIT/BSD for Mesa, GPL-2.0-or-later
for the port's own additions). Horizon links the driver statically, so an
application that links it forms a combined work covered by the GPL: you may
ship binaries freely, but the corresponding source must be available to
whoever receives them. See `references/nxvk/licenses/` and the port's
`switch/README.md`.

## Not included

Blizzard client data (MPQs, DBCs) is not part of this repository. Copy your own
WotLK client `Data` directory to `sdmc:/wowps/Data` on the console.