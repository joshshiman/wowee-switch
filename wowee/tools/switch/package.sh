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
BIN="$BUILD_DIR/bin"
NRO="$BIN/wowee.nro"
[ -s "$NRO" ] || die "missing build output: $NRO"

APP_DIR="$STAGE_DIR/switch/wowee"
mkdir -p "$APP_DIR"

cp -f "$NRO" "$APP_DIR/wowee.nro"
cp -f "$BIN/wowee.elf" "$APP_DIR/wowee.elf" 2>/dev/null || true

# The bundled addons are read from the .nro's romfs when present; when the
# build staged them on disk instead, keep a copy beside the .nro.
if [ -d "$BIN/addons" ]; then
    cp -r "$BIN/addons" "$APP_DIR/addons"
fi

cat <<EOF

Staged homebrew:
  $APP_DIR/wowee.nro

To run it on the console (with Atmosphere / a homebrew loader):
  1. Copy this directory to the SD card: $STAGE_DIR/switch/wowee/
  2. Copy your own WotLK client 'Data' directory to:  sdmc:/wowps/Data
     (locale subdirectories and the MPQ layout must be kept as-is)
  3. Launch 'WoWee' from the homebrew menu.
EOF