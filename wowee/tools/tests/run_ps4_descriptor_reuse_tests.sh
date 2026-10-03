#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
"${CC:-cc}" -std=c11 -O1 -g -fsanitize=address,undefined \
  -ffunction-sections -fdata-sections \
  -I "$project_root/switch/third_party/nxvk/include" \
  "$project_root/tools/tests/switch_descriptor_reuse_test.c" \
  "$project_root/switch/third_party/nxvk/source/vulkan-switch/src/vk_switch_descriptor.c" \
  -Wl,--gc-sections -o "$work_dir/descriptor_reuse"
# LeakSanitizer cannot operate under the workspace's tracing; memory/bounds and
# undefined-behavior instrumentation remain enabled.
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$work_dir/descriptor_reuse"
