#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
ar p "$project_root/switch/third_party/nxvk/lib/libopengnm.a" drawcommandbuffer.o > "$work_dir/drawcommandbuffer.o"
ar p "$project_root/switch/third_party/nxvk/lib/libopengnm.a" depthrendertarget.o > "$work_dir/depthrendertarget.o"
ar p "$project_root/switch/third_party/nxvk/lib/libopengnm.a" dataformat.o > "$work_dir/dataformat.o"
ar p "$project_root/switch/third_party/nxvk/lib/libopengnm.a" tilemodes.o > "$work_dir/tilemodes.o"
python3 - "$work_dir/drawcommandbuffer.o" "$work_dir/depthrendertarget.o" "$work_dir/dataformat.o" "$work_dir/tilemodes.o" "$work_dir/unused_gnm_stubs.c" <<'PY'
import pathlib, subprocess, sys
source = '#include <stdlib.h>\n#include <stdio.h>\n#include <stdint.h>\nuintptr_t __stack_chk_guard = 0x257;\n'
objects = sys.argv[1:5]
defined = {line.split()[-1] for line in subprocess.check_output(['nm', '--defined-only', *objects], text=True).splitlines() if len(line.split()) >= 3}
undefined = {line.split()[-1] for line in subprocess.check_output(['nm', '-u', *objects], text=True).splitlines() if len(line.split()) == 2}
for name in sorted(undefined - defined):
    if name.startswith(('sceGnm', 'sceGpa')) and name != 'sceGnmDriverDrawIndex':
        source += 'void ' + name + '(void) { fputs("unexpected '+name+'\\n", stderr); abort(); }\n'
for name in ['sceGnmCmdInit','sceGnmDirectMemoryAllocate','sceGnmCmdAllocInside','vk_switch_alloc','vk_switch_free','vk_switch_alloc_gpu','vk_switch_free_gpu','vk_switch_descriptor_write_dirty','vk_switch_vk_format_to_gnm_buffer']:
    source += 'void ' + name + '(void) { fputs("unexpected '+name+'\\n",stderr); abort(); }\n'
pathlib.Path(sys.argv[5]).write_text(source)
PY
command_source="${BACKEND_COMMAND_SOURCE:-$project_root/switch/third_party/nxvk/source/vulkan-switch/src/vk_switch_command.c}"
"${CC:-cc}" -DBACKEND_COMMAND_SOURCE=\""$command_source"\" -std=c11 -O1 -g -ffunction-sections -fdata-sections \
  -I "$project_root/switch/third_party/nxvk/include" \
  "$project_root/tools/tests/switch_direct_draw_state_test.c" \
  "$work_dir/drawcommandbuffer.o" "$work_dir/depthrendertarget.o" "$work_dir/dataformat.o" "$work_dir/tilemodes.o" "$work_dir/unused_gnm_stubs.c" \
  -Wl,--gc-sections -lm -o "$work_dir/depth_draw_receipt"
"$work_dir/depth_draw_receipt"
sha256sum "$project_root/switch/third_party/nxvk/lib/libopengnm.a"
