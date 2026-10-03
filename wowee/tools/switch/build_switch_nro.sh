#!/usr/bin/env bash
# Configure, build and stage the Switch client with devkitPro.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_DIR/build-switch"
CONFIG="Release"
JOBS=""
CLEAN=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Build WoWee for the Nintendo Switch and stage the .nro for an SD card.

Usage: tools/switch/build_switch_nro.sh [options]

  --clean                Remove the selected build directory before building.
  --jobs N, -j N         Parallel compile jobs; defaults to the host CPU count.
  --build-dir DIR        Build directory; defaults to ./build-switch.
  --config CONFIG        Release, Debug, RelWithDebInfo or MinSizeRel.
  --stage-dir DIR        Where to put the SD-card layout; defaults to ./out/switch.
  -h, --help             Show this help.

Environment:
  DEVKITPRO         devkitPro root (devkitA64 + libnx + portlibs).
  PKG_CONFIG_PATH   must contain the nxvk portlib's pkgconfig dir.

Requires the nxvk (Mesa NVK) devkitPro portlib:
  https://github.com/PalindromicBreadLoaf/nxvk  (make image && make && sudo make install)

Output:
  <build-dir>/wowee.nro
  <build-dir>/wowee-data/              (runtime assets read from the SD card)
  <stage-dir>/switch/wowee/wowee.nro   (copy the stage dir to the SD card root)
USAGE
}

STAGE_DIR="$REPO_DIR/out/switch"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        -j|--jobs|--build-dir|--config|--stage-dir)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
            case "$1" in
                -j|--jobs) JOBS="$2" ;;
                --build-dir) BUILD_DIR="$2" ;;
                --config) CONFIG="$2" ;;
                --stage-dir) STAGE_DIR="$2" ;;
            esac
            shift 2 ;;
        --jobs=*) JOBS="${1#*=}"; shift ;;
        --build-dir=*) BUILD_DIR="${1#*=}"; shift ;;
        --config=*) CONFIG="${1#*=}"; shift ;;
        --stage-dir=*) STAGE_DIR="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1'; use --help" ;;
    esac
done

case "$CONFIG" in
    Release|Debug|RelWithDebInfo|MinSizeRel) ;;
    *) die "unsupported build configuration '$CONFIG'" ;;
esac
if [ -z "$JOBS" ]; then
    JOBS="$( (nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4) | tr -d '[:space:]')"
fi
[[ "$JOBS" =~ ^[0-9]+$ ]] && [[ "$JOBS" =~ [1-9] ]] || die "--jobs must be a positive integer"

for tool in cmake ninja python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool was not found on PATH; see README.md"
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || die "Python 3.10 or newer is required"

[ -n "${DEVKITPRO:-}" ] || die "set DEVKITPRO to the devkitPro root; see README.md"
for f in devkitA64/bin/aarch64-none-elf-gcc libnx/switch.specs libnx/include/switch.h; do
    [ -e "$DEVKITPRO/$f" ] || die "devkitPro install is missing $f"
done
PKGCFG="${PKG_CONFIG_PATH:-$DEVKITPRO/portlibs/switch/lib/pkgconfig}"
# The driver can be installed either as a built portlib (nvxk.pc) or as a
# prebuilt libvulkan.a dropped into portlibs/switch; cmake/switch/nxvk.cmake
# detects both.
if [ ! -f "$PKGCFG/nxvk.pc" ] && [ ! -f "$DEVKITPRO/portlibs/switch/lib/libvulkan.a" ]; then
    die "the nxvk driver is not installed (expected $PKGCFG/nxvk.pc or portlibs/switch/lib/libvulkan.a); see README.md"
fi

if [ "$CLEAN" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
    printf '==> removing %s\n' "$BUILD_DIR"
    rm -rf -- "$BUILD_DIR"
fi

export DEVKITPRO
export PKG_CONFIG_PATH="$PKGCFG"

printf '==> configure (%s)\n' "$CONFIG"
cmake -S "$REPO_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$REPO_DIR/cmake/switch.toolchain.cmake" \
    -DCMAKE_BUILD_TYPE="$CONFIG"
printf '==> build (%s jobs)\n' "$JOBS"
cmake --build "$BUILD_DIR" --parallel "$JOBS"

NRO="$BUILD_DIR/wowee.nro"
[ -s "$NRO" ] || die "build did not produce $NRO"
[ -d "$BUILD_DIR/wowee-data" ] || die "build did not stage $BUILD_DIR/wowee-data"

printf '==> stage\n'
"$REPO_DIR/tools/switch/package.sh" "$BUILD_DIR" "$STAGE_DIR"

printf '\nNRO: %s (%s bytes)\nStaged: %s/switch/wowee/wowee.nro\n' \
    "$NRO" "$(wc -c < "$NRO" | tr -d '[:space:]')" "$STAGE_DIR"
printf 'On the console: copy your WotLK client Data/ to sdmc:/wowps/Data.\n'