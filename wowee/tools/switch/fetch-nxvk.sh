#!/usr/bin/env bash
# Install the Vulkan driver this port renders through.
#
# WoWee on the Switch draws through Mesa's NVK Vulkan driver, ported to the
# console as a devkitPro portlib by PalindromicBreadLoaf:
#
#   https://github.com/PalindromicBreadLoaf/nxvk
#
# That port is built from Mesa with podman/docker, so this script does the
# clone + build + install and stops with the URL when the container runtime is
# missing.
#
#   tools/switch/fetch-nxvk.sh [dest-dir]
#
# After it finishes, $DEVKITPRO/portlibs/switch/lib/pkgconfig/nxvk.pc exists
# and cmake/switch/nxvk.cmake picks the driver up through pkg-config.
set -euo pipefail

DEST="${1:-$(pwd)/nxvk}"
REPO="https://github.com/PalindromicBreadLoaf/nxvk.git"

if [ ! -f "${DEVKITPRO:-$DEVKITPRO_UNSET}/portlibs/switch/lib/pkgconfig/nxvk.pc" ]; then
    :
else
    echo "nxvk portlib already installed; nothing to do."
    exit 0
fi

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }

if [ ! -d "$DEST/.git" ]; then
    echo "==> cloning $REPO into $DEST"
    git clone --depth 1 --branch switch "$REPO" "$DEST"
fi

if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<EOF

The nxvk driver is built inside a container image, and neither podman nor
docker was found on PATH.

  1. Install podman or docker
  2. Re-run: tools/switch/fetch-nxvk.sh $DEST

then, inside $DEST:

  make image     # build the toolchain image (once)
  make           # build libnvk.a + the portlib package
  sudo make install

EOF
    exit 1
fi

cd "$DEST"
echo "==> make image (toolchain container)"
make image
echo "==> make (driver + portlib staging)"
make
echo "==> make install (copies into \$DEVKITPRO/portlibs/switch)"
sudo make install

echo
echo "nxvk installed. Configure the client with:"
echo "  export DEVKITPRO=/opt/devkitpro   # or wherever devkitPro lives"
echo "  tools/switch/build_switch_nro.sh"