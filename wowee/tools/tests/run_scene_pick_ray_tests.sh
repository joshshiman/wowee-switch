#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
SAN_FLAGS=()
if [ "${SANITIZE:-0}" = 1 ]; then SAN_FLAGS=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
# The picking ray, the picking helpers and the input edges a click arrives on.
# src/core/input.cpp is compiled here because it is the code under test: the
# edges it answers with are the ones the pick is gated on.
"${CXX:-c++}" -std=c++20 -O1 -g "${SAN_FLAGS[@]}" \
    $(pkg-config --cflags sdl2) \
    -DGLM_FORCE_DEPTH_ZERO_TO_ONE \
    -I"$ROOT/include" -I"$ROOT/extern/glm" \
    "$ROOT/tools/tests/scene_pick_ray_test.cpp" \
    "$ROOT/src/core/input.cpp" "$ROOT/src/rendering/camera.cpp" \
    $(pkg-config --libs sdl2) \
    -Wl,--gc-sections -pthread -o "$TEST_DIR/scene_pick_ray_test"
SDL_VIDEODRIVER=dummy "$TEST_DIR/scene_pick_ray_test"
