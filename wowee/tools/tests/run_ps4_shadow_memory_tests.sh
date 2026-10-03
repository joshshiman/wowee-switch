#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
backend="$project_root/switch/third_party/nxvk"
"${CC:-cc}" -std=c11 -O1 -g -ffunction-sections -fdata-sections \
  -I "$backend/include" -c "$backend/source/vulkan-switch/src/vk_switch_instance.c" -o "$work_dir/instance.o"
"${CXX:-c++}" -std=c++17 -O1 -g -ffunction-sections -fdata-sections \
  -I "$backend/include" -I "$project_root/include" -I "$project_root/extern" \
  "$project_root/tools/tests/switch_shadow_memory_test.cpp" "$work_dir/instance.o" \
  -Wl,--gc-sections -pthread -o "$work_dir/selection"
"$work_dir/selection"
