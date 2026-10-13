# Getting started

**[README.md](../README.md) is the guide** — what you need, how to install it,
how to run a server and how to play. *This* file is the long version of the
**Linux build path**: from a bare machine to a packaged `wowee.nro`, verified end
to end on CachyOS (Arch family, glibc, pacman) on 2026-10-08. Clone
`https://github.com/joshshiman/wowee-switch.git` and work from its root.

It keeps the depth the README doesn't: the nxvk driver in full (prebuilt and
built from source), the native host build, the artifact sanity checks, and the
configure problems that silently break a naive attempt.

---

## What you need

[README.md § What you need](../README.md#what-you-need) lists the console, host,
toolchain, driver, game data, server and disk requirements. Two points are
specific to this path:

- **Your own copy** of a WotLK 3.3.5a `Data` directory — the `.MPQ` archives with
  their locale subdirectories intact, roughly 15 GB. Blizzard's game data is not
  included and cannot be.
- About 120 MB of downloads for the toolchain, plus a few GB of disk.

**Read [README.md § Project status](../README.md#project-status) first.** It is
the honest account of what still doesn't work. Building proves the code compiles
and links; it does not prove the title boots.

---

## 1. Install devkitPro

CachyOS ships pacman, so use devkitPro's "customising an existing pacman
install" path rather than their self-contained installer. Register their signing
key first:

```sh
sudo pacman-key --recv BC26F752D25B92CE272E0F44F7FD5492264BB9D0 --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign BC26F752D25B92CE272E0F44F7FD5492264BB9D0
sudo pacman -U --noconfirm https://pkg.devkitpro.org/devkitpro-keyring.pkg.tar.zst
sudo pacman-key --populate devkitpro
```

`--populate` is not optional: it is what makes the newly installed
`devkitpro-keyring` package trust its own repositories.

### Adding the repositories without touching `/etc/pacman.conf`

The wiki says to edit `/etc/pacman.conf` and add two repos. You do not have to —
pacman will take a config file of your own, which leaves the system one alone:

```sh
mkdir -p ~/.config
cat > ~/.config/pacman-dkp.conf <<'CONF'
Include = /etc/pacman.conf

[dkp-libs]
Server = https://pkg.devkitpro.org/packages

[dkp-linux]
Server = https://pkg.devkitpro.org/packages/linux/$arch/
CONF

sudo pacman --config ~/.config/pacman-dkp.conf -Sy
```

`dkp-linux` is the right repo for a glibc system; musl-based distros (Alpine,
Void) need `dkp-linux-musl` instead.

Then install the toolchain. Note that **`switch-dev` is a group, not a package**,
so `pacman -Si switch-dev` finds nothing and it will not appear in `-S --print`
as a single package:

```sh
sudo pacman --config ~/.config/pacman-dkp.conf -S --noconfirm switch-dev switch-zlib
```

That is 19 packages and about 118 MB, and gives you devkitA64 GCC, libnx,
`elf2nro`, `nacptool` and `build_romfs`. Then:

```sh
source /etc/profile.d/devkit-env.sh     # sets DEVKITPRO et al.
echo "$DEVKITPRO"                       # should be /opt/devkitpro
```

Verify the cross-compiler before going further:

```sh
"$DEVKITPRO"/devkitA64/bin/aarch64-none-elf-gcc --version
```

### If `dkp-pacman` cannot reach the servers

If the devkitPro servers are unreachable from your network, the same toolchain
can be unpacked from their published container image instead. That needs podman
or docker, which is a heavier prerequisite than the repo path above, so try the
repo path first.

---

## 2. Install the Vulkan driver (nxvk)

The renderer speaks Vulkan through **Mesa NVK**, ported to the Switch as
**nxvk**. `PalindromicBreadLoaf/nxvk` — the upstream port — has **no releases at
all**, so `libvulkan.a` cannot be downloaded from it: building it means compiling
Mesa in a container, which needs podman or docker and a long build. The port
ships a helper that does that clone-and-build for you:

```sh
wowee/tools/switch/fetch-nxvk.sh    # clone the switch branch, then make image / make / sudo make install
```

The easier path is the prebuilt drop-in at `jhuz0/nvk-switch`, which publishes
exactly that archive (Mesa 25.0.7):

```sh
mkdir -p /tmp/nxvk && cd /tmp/nxvk
curl -fsSLO https://github.com/jhuz0/nvk-switch/releases/download/nvk-switch-mesa-25.0.7-r1/nvk-switch-25.0.7.tar.xz
curl -fsSLO https://github.com/jhuz0/nvk-switch/releases/download/nvk-switch-mesa-25.0.7-r1/libvulkan.a
tar xf nvk-switch-25.0.7.tar.xz
```

That gives you `lib/libvulkan.a` and `include/vulkan/`. The build looks for them
in `$DEVKITPRO/portlibs/switch`:

```sh
sudo install -d /opt/devkitpro/portlibs/switch/lib \
               /opt/devkitpro/portlibs/switch/include/vulkan
sudo install -m644 lib/libvulkan.a /opt/devkitpro/portlibs/switch/lib/
sudo install -m644 include/vulkan/*.h /opt/devkitpro/portlibs/switch/include/vulkan/
sudo install -m644 NOTICE.md /opt/devkitpro/portlibs/switch/
```

**Ship the `NOTICE.md`.** Linking the statically-linked Mesa driver makes the
resulting binary a combined work under the GPL, and that file is the
corresponding-source pointer.

### The `vk_video` trap

**The prebuilt archive is incomplete, and the compile fails without this step.**
Its `vulkan_core.h` includes `vk_video/vulkan_video_codec_h264std.h`, but the
archive ships no `vk_video/` directory. Any translation unit that touches Vulkan
dies with `fatal error: vk_video/vulkan_video_codec_h264std.h: No such file or
directory` — which in practice means `imgui_impl_vulkan.cpp`, early in the
build.

The fix is *not* to grab the newest `vk_video` headers. They must match the
archive, whose `vulkan_core.h` is `VK_HEADER_VERSION 305`:

```sh
grep 'define VK_HEADER_VERSION' /opt/devkitpro/portlibs/switch/include/vulkan/vulkan_core.h
```

`VK_HEADER_VERSION 305` is **Vulkan-Headers tag `v1.4.305`**. Take the video
headers from that tag, not from `main`:

```sh
cd /tmp && git clone --filter=blob:none --no-checkout https://github.com/KhronosGroup/Vulkan-Headers.git
cd Vulkan-Headers && git checkout v1.4.305 -- include/vk_video
sudo install -d /opt/devkitpro/portlibs/switch/include/vk_video
sudo install -m644 include/vk_video/*.h /opt/devkitpro/portlibs/switch/include/vk_video/
```

### Alternative: keep it pacman-tracked

Dropping files into `/opt/devkitpro` by hand leaves them untracked and
unremovable by your package manager. If you would rather have them managed, wrap
the same two directories in a local package — then `pacman -U` installs it and
`pacman -R` removes it, and the `vk_video` headers ride along in the same
package:

```sh
# PKGBUILD
pkgname=nxvk-switch
pkgver=25.0.7
pkgrel=1
pkgdesc="Prebuilt NVK (Mesa Vulkan driver) for Nintendo Switch homebrew"
arch=('any')
license=('MIT')
provides=('libvulkan')

source=("nvk-switch-25.0.7.tar.xz")
sha256sums=('SKIP')

package() {
    install -Dm644 lib/libvulkan.a "$pkgdir/opt/devkitpro/portlibs/switch/lib/libvulkan.a"
    install -dm755 "$pkgdir/opt/devkitpro/portlibs/switch/include/vulkan"
    install -m644 include/vulkan/*.h "$pkgdir/opt/devkitpro/portlibs/switch/include/vulkan/"
    # vk_video/ comes from Vulkan-Headers v1.4.305 — see the trap above.
    install -dm755 "$pkgdir/opt/devkitpro/portlibs/switch/include/vk_video"
    install -m644 "$startdir"/vk_video/*.h "$pkgdir/opt/devkitpro/portlibs/switch/include/vk_video/"
    install -Dm644 NOTICE.md "$pkgdir/opt/devkitpro/portlibs/switch/NOTICE.md"
}
```

---

## 3. Put your game data where the client looks

Copy your own WotLK `Data` directory to `wowps/Data` inside the repo — that is
local-only and git-ignored, and it mirrors the console's `sdmc:/wowps/Data`:

```sh
mkdir -p ~/Projects/wowee-switch/wowps
cp -a /path/to/your/WotLK-3.3.5a/Data ~/Projects/wowee-switch/wowps/Data
```

Keep the locale subdirectory (`Data/enUS/`, and so on) intact; the MPQ layout is
read as-is.

---

## 4. Build

```sh
cd ~/Projects/wowee-switch
DEVKITPRO=/opt/devkitpro cmake -S $PWD/wowee -B build-switch -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=$PWD/wowee/cmake/switch.toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release
DEVKITPRO=/opt/devkitpro cmake --build build-switch --parallel "$(nproc)"
DEVKITPRO=/opt/devkitpro cmake --build build-switch --target switchpkg
```

Two things that will cost you time if you miss them:

- **`CMAKE_TOOLCHAIN_FILE` must be an absolute path.** A relative one fails
  during the very first `project()` call with "Could not find toolchain file",
  which reads like a missing file rather than a path problem.
- **The scripts in `wowee/tools/switch/` must be executable.** They are invoked
  directly, and on a native Linux clone they are committed non-executable, so
  the first documented command fails with `Permission denied`. If a fresh clone
  still trips on this: `git update-index --chmod=+x wowee/tools/switch/*.sh
  wowee/tools/cli/*.py`.

A good configure ends with these two lines, which tell you the driver was found:

```
-- Vulkan backend for Switch: nxvk (prebuilt) at /opt/devkitpro/portlibs/switch
-- WoWee: Nintendo Switch / libnx + devkitPro + nxvk
```

If it says `(portlib)` instead of `(prebuilt)`, it is picking up an
`nxvk.pc`-style installation — also fine. If it stops with
`No Vulkan driver for the Switch under ...`, the driver from step 2 is missing
or in the wrong place.

### What a successful build looks like

727 targets, no errors, roughly four minutes on 16 cores:

| Artifact | Size |
|----------|------|
| `build-switch/wowee.elf` | ~45 M |
| `build-switch/wowee-romfs.bin` | ~38 M |
| `build-switch/wowee.nro` | ~75 M |

Worth checking the ELF before you burn an SD card:

```sh
# the driver's one real entry point must be exported
nm build-switch/wowee.elf | grep -w vk_icdGetInstanceProcAddr
# and there must be no unresolved symbols
aarch64-none-elf-nm -u build-switch/wowee.elf | wc -l
```

---

## 5. Stage it for the SD card

`switchpkg` assembles the tree for you:

```
wowee/out/switch/switch/wowee/wowee.nro
wowee/out/switch/switch/wowee/data/          assets/shaders, Data/expansions, Data/opcodes
wowee/out/switch/switch/wowee/addons/
```

Copy that `wowee` folder to `sdmc:/switch/` and put your game data at
`sdmc:/wowps/Data`. The card layout, the FTP deploy script and the launch notes
(Title Override for full memory) are in
[README.md § Put it on your Switch](../README.md#2-put-it-on-your-switch).

---

## Optional: a native host build

You do not need any of the above to iterate on the client. The same tree builds
natively with `WOWEE_SWITCH=OFF` — useful for compile-checking a change in
seconds rather than minutes, and for reading the logs without an SD card swap:

```sh
# the system vulkan.pc provides -lvulkan but no headers, so point at a clone
git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git deps/vulkan-headers

cmake -S wowee -B build-host -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DVulkan_INCLUDE_DIR=$PWD/deps/vulkan-headers/include
cmake --build build-host --parallel "$(nproc)"
```

Then run it against the game data you staged above:

```sh
WOW_DATA_PATH=$PWD/wowps ./build-host/bin/wowee
```

Logs go to `build-host/bin/logs/wowps.log`, not stdout. With no data present it
boots, builds its Vulkan pipelines, and tells you exactly what it could not find
— a good control for "is my change broken, or is it just the data path?".

---

## Known gaps

- **Toolchain drift.** These steps were verified with devkitA64 GCC 16.1.0. The
  build this port was originally verified against used 15.2, so treat size and
  behavioural differences with suspicion.
- **Asset staging does not notice shader edits.** Staging hangs off the link
  edge with no stamp target or `BYPRODUCTS`, so editing a `.glsl` and rebuilding
  leaves the *old* `.spv` in `wowee-data/`. If you change shaders, reconfigure
  or delete `build-switch/wowee-data` by hand. See the build findings in
  [AUDIT_FIRST_RUN.md](AUDIT_FIRST_RUN.md).
- **The card's `data/` wins over the `.nro`'s romfs.** `switchpkg` embeds a romfs
  in the title, but the resource root resolves in this order:
  `WOWEE_RESOURCE_ROOT` → `data/` beside the `.nro` → the `.nro`'s own directory
  → `sdmc:/switch/<stem>/data` → the embedded romfs → `sdmc:/switch/wowee/data`.
  On a normal install the card's `data/` is chosen and the romfs is only a
  fallback, so **an asset change means rebuilding and redeploying the `.nro`**.
  `boot.log` records the choice (`resource root: …`) and rejects (`not used: …`);
  see [README.md § SD card layout](../README.md#sd-card-layout).

---

## Licensing

Blizzard game data is not included and this project is not affiliated with or
endorsed by Blizzard Entertainment. Linking the statically-linked Mesa NVK
driver makes the binary a combined work under the GPL — distribute the
corresponding source with any binary you build. See
[PORTING.md](PORTING.md#licensing).
