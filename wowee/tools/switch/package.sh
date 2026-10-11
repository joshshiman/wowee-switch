#!/usr/bin/env bash
# Stage a built Switch homebrew into an SD-card layout.
#
# Homebrew loaders take the .nro straight from the SD card, so there is no
# package to build: this copies the artifacts into the layout a console
# expects and prints what the user still has to supply themselves (their own
# game client data).
#
#   tools/switch/package.sh <build-dir> [stage-dir]
set -euo pipefail

BUILD_DIR="${1:?usage: package.sh <build-dir> [stage-dir]}"
STAGE_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/out/switch}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$BUILD_DIR" ] || die "build directory not found: $BUILD_DIR"
# The Switch target writes its artifacts straight into the build directory;
# accept a bin/ subdirectory too so a staged build tree keeps working.
if [ -s "$BUILD_DIR/wowee.nro" ]; then
    BIN="$BUILD_DIR"
else
    BIN="$BUILD_DIR/bin"
fi
NRO="$BIN/wowee.nro"
[ -s "$NRO" ] || die "missing build output: $NRO"

APP_DIR="$STAGE_DIR/switch/wowee"
mkdir -p "$APP_DIR"

cp -f "$NRO" "$APP_DIR/wowee.nro"
cp -f "$BIN/wowee.elf" "$APP_DIR/wowee.elf" 2>/dev/null || true

# Runtime assets are staged beside the binary (build-switch/wowee-data) rather
# than embedded in the .nro: this devkitPro elf2nro cannot read a romfs, and a
# side-by-side directory lets shaders be refreshed without a rebuild.
if [ -d "$BUILD_DIR/wowee-data" ]; then
    rm -rf "$APP_DIR/data"
    cp -r "$BUILD_DIR/wowee-data" "$APP_DIR/data"
else
    echo "warning: $BUILD_DIR/wowee-data is missing; the client will not find its" >&2
    echo "         shaders. Build with the wowee target first." >&2
fi

# The bundled addons are read from the same tree when present.
if [ -d "$BIN/addons" ]; then
    rm -rf "$APP_DIR/addons"
    cp -r "$BIN/addons" "$APP_DIR/addons"
    rm -rf "$APP_DIR/data/addons"
    cp -r "$BIN/addons" "$APP_DIR/data/addons"
fi

cat <<EOF

Staged homebrew:
  $APP_DIR/wowee.nro
  $APP_DIR/data/            (assets/shaders, Data/expansions, Data/opcodes)

To run it on the console (with Atmosphere / a homebrew loader):
  1. Copy this directory to the SD card: $STAGE_DIR/switch/wowee/
  2. Copy your own WotLK client 'Data' directory to:  sdmc:/wowps/Data
     (locale subdirectories and the MPQ layout must be kept as-is)
  3. Launch 'WoWee' from the homebrew menu.
EOF