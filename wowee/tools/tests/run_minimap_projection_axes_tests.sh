#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
san_flags=()
if [ "${SANITIZE:-0}" = 1 ]; then san_flags=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
"${CXX:-c++}" -std=c++20 -O1 -g "${san_flags[@]}" -I"$root/include" -I"$root/extern/glm" \
    "$root/tools/tests/minimap_projection_axes_test.cpp" -o "$tmpdir/test"
"$tmpdir/test" "$root"
