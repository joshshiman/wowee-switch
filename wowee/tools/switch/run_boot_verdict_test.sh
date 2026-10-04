#!/usr/bin/env bash
# The first-boot self-test line is the thing a first hardware run is read
# through, and the console is the one place a wrong field order is found by a
# player rather than by a test. So it is asserted here, off-console.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
FLAGS=(-std=c++20 -O1 -g -Wall -Wextra -I"$ROOT/include")
if [ "${SANITIZE:-0}" = 1 ]; then
    FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
    export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
    export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}"
fi
"${CXX:-c++}" "${FLAGS[@]}" "$ROOT/tools/switch/boot_verdict_test.cpp" \
    "$ROOT/src/platform/switch/boot_verdict.cpp" -o "$TEST_DIR/boot-verdict"
"$TEST_DIR/boot-verdict"