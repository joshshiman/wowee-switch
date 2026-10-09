#!/usr/bin/env python3
"""Fail the build if devkitA64 has miscompiled a thread_local access.

One flag combination in the toolchain file turns every `thread_local` in the
client into a data abort on hardware. With `-mtp=soft` and PIE, g++ emits

    bl   __aarch64_read_tp
    ldr  w0, [x0, x0]        <-- base and index are both the thread pointer

The load reads 2 * TP, which is unmapped, and the instruction carries no
relocation for the linker to fix up. No symbolization helps: the function is
just `SErrGetLastError`, so the only trace is a crash report with a data abort
and a fault address that is exactly twice the thread pointer.

The symptom on hardware is instant and total. StormLib's SFileOpenArchive calls
SErrGetLastError while opening an archive, so the title aborted during the asset
phase on every run while building, packaging and running perfectly on the host -
the host build does not use these flags. Six console runs were spent reproducing
what one pass over the linked ELF would have caught.

`-ftls-model=local-exec` in cmake/switch.toolchain.cmake is the fix, and this
tool is what keeps it. It looks for the miscompiled shape directly: a load or
store whose address operand names the same register as both base and index,
where that register was the return of __aarch64_read_tp. A self-indexed access
anywhere else is legal (odd, but legal) and is reported separately so the count
of the real thing stays meaningful.

    tools/switch/verify_tls_access.py <elf-or-obj> [...]

Exit status is 1 if the miscompiled shape is found, 0 otherwise.
"""

import re
import os
import shutil
import subprocess
import sys
from pathlib import Path

# The target's objdump, in the order they are tried. devkitPro is not normally
# on PATH, and the host objdump cannot read aarch64 objects, so the toolchain
# bin dir comes first.
OBJDUMP_CANDIDATES = [
    os.environ.get("OBJDUMP"),
    os.path.join(os.environ.get("DEVKITPRO", "/opt/devkitpro"), "devkitA64/bin",
                 "aarch64-none-elf-objdump"),
    shutil.which("aarch64-none-elf-objdump"),
    "objdump",
]


def find_objdump():
    for candidate in OBJDUMP_CANDIDATES:
        if candidate and (shutil.which(candidate) or Path(candidate).is_file()):
            return candidate
    sys.exit("error: no objdump found; set OBJDUMP to the target binutils "
             "objdump (devkitA64/bin/aarch64-none-elf-objdump)")

# ldr/str wN, [xN, xN] - a load or store addressed as base+index of one register.
# objdump's line is "  <addr>:\t<mnemonic>\t<operands>", so the address prefix is
# consumed before the mnemonic.
SELF_INDEXED = re.compile(
    r"^\s+[0-9a-f]+:\s+(?:ldr|str|ldrb|strb|ldrh|strh|ldrsw)\s+\w+,\s*\[(\w+), (\w+)\]"
)
# The tp getter libnx provides for -mtp=soft.
READ_TP = "__aarch64_read_tp"


def instruction_lines(path):
    """Disassembly of the file's .text, as one list of instruction strings."""
    cmd = [find_objdump(), "-d", "--no-show-raw-insn", str(path)]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        sys.exit(f"error: cannot disassemble {path} with {cmd[0]}: {exc}")
    return out.splitlines()


def function_of(lines):
    """Yield (function name, its instruction lines) per function in the dump."""
    name, body = None, []
    for line in lines:
        header = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if header:
            if name:
                yield name, body
            name, body = header.group(1), []
        elif re.match(r"^\s+[0-9a-f]+:", line):
            body.append(line)
    if name:
        yield name, body


def scan(path):
    """Return (miscompiled, other-self-indexed) with 'file:func:addr' strings."""
    broken, benign = [], []
    for func, body in function_of(instruction_lines(path)):
        tp_from_read_tp = False
        for line in body:
            # A call to the thread-pointer getter makes the register it returns
            # the TP, and a self-indexed access off that is the miscompile.
            if READ_TP in line and "\tbl" in line:
                tp_from_read_tp = True
                continue
            match = SELF_INDEXED.match(line)
            if not match:
                continue
            # Only a self-indexed access counts: base and index the same
            # register. Any other register-offset access is ordinary code.
            if match.group(1) != match.group(2):
                continue
            where = f"{path.name}:{func}:{line.split(':')[0].strip()}"
            (broken if tp_from_read_tp else benign).append(where)
    return broken, benign


def main(argv):
    targets = argv[1:]
    if not targets:
        sys.exit(__doc__)

    any_broken = []
    for raw in targets:
        path = Path(raw)
        if not path.is_file():
            sys.exit(f"error: no such file: {path}")
        broken, benign = scan(path)
        if benign:
            print(f"note: {path.name}: {len(benign)} self-indexed access(es) not "
                  f"fed by __aarch64_read_tp (legal, left alone)")
        if broken:
            any_broken.append((path, broken))

    if any_broken:
        for path, broken in any_broken:
            print(f"FAIL {path.name}: {len(broken)} thread_local access(es) "
                  f"miscompiled into a self-indexed load")
            for where in broken[:12]:
                print(f"      {where}")
            if len(broken) > 12:
                print(f"      ... and {len(broken) - 12} more")
        print()
        print("The build will run on the host and data-abort instantly on the")
        print("console. cmake/switch.toolchain.cmake must carry")
        print("-ftls-model=local-exec; without it g++ computes 2 * the thread")
        print("pointer and dereferences that. See the comment there.")
        return 1

    print(f"PASS {', '.join(Path(t).name for t in targets)}: no thread_local "
          f"access miscompiled (no self-indexed load after __aarch64_read_tp)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
