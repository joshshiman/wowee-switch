#!/usr/bin/env python3
"""Dump the push-constant and descriptor layouts a SPIR-V module declares.

The client ships precompiled .spv files, and only the lighting set is covered by
tools/switch/verify_shaders.py. A shader whose source changed after its .spv was
produced still loads and still passes validation - it just reads the wrong
bytes. This prints what the binary declares, which is what the C++ push
constant structs and descriptor layouts have to agree with.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

SPIRV_MAGIC = 0x07230203

OP_NAME = {
    5: "OpName", 6: "OpMemberName", 11: "OpExtInstImport", 14: "OpMemoryModel",
    15: "OpEntryPoint", 16: "OpExecutionMode", 17: "OpCapability",
    19: "OpTypeVoid", 20: "OpTypeBool", 21: "OpTypeInt", 22: "OpTypeFloat",
    23: "OpTypeVector", 24: "OpTypeMatrix", 25: "OpTypeImage",
    26: "OpTypeSampler", 27: "OpTypeSampledImage", 28: "OpTypeArray",
    29: "OpTypeRuntimeArray", 30: "OpTypeStruct", 32: "OpTypePointer",
    33: "OpTypeFunction", 41: "OpConstantTrue", 42: "OpConstantFalse",
    43: "OpConstant", 44: "OpConstantComposite", 45: "OpConstantSampler",
    46: "OpConstantNull", 54: "OpFunction", 55: "OpFunctionParameter",
    56: "OpFunctionEnd", 59: "OpVariable", 61: "OpLoad", 62: "OpStore",
    65: "OpAccessChain", 71: "OpDecorate", 72: "OpMemberDecorate",
}

STORAGE_CLASS = {
    0: "UniformConstant", 1: "Input", 2: "Uniform", 3: "Output",
    4: "Workgroup", 5: "CrossWorkgroup", 6: "Private", 7: "Function",
    8: "Generic", 9: "PushConstant", 10: "AtomicCounter", 11: "Image",
    12: "StorageBuffer",
}

DECORATION = {
    0: "RelaxedPrecision", 1: "SpecId", 2: "Block", 3: "BufferBlock",
    4: "RowMajor", 5: "ColMajor", 6: "ArrayStride", 7: "MatrixStride",
    8: "GLSLShared", 9: "GLSLPacked", 10: "CPacked", 11: "BuiltIn",
    12: "NoPerspective", 13: "Flat", 14: "Patch", 15: "Centroid",
    16: "Sample", 17: "Invariant", 18: "Restrict", 19: "Aliased",
    20: "Volatile", 21: "Constant", 22: "Coherent", 23: "NonWritable",
    24: "NonReadable", 25: "Uniform", 26: "UniformId", 27: "SaturatedConversion",
    28: "Stream", 29: "InputAttachmentIndex", 30: "Location", 31: "Component",
    32: "Index", 33: "DescriptorSet", 34: "Binding", 35: "Offset",
    36: "XfbBuffer", 37: "XfbStride", 38: "FuncParamAttr", 42: "Alignment",
}

OFFSET = 35
BINDING = 34
DESCRIPTOR_SET = 33

TYPE_OPCODES = (19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 32, 33)


def read_words(data: bytes) -> list[int]:
    if len(data) < 20 or len(data) % 4:
        raise ValueError("not a SPIR-V module (%d bytes)" % len(data))
    # Five-word header, no length field: instructions run to end of file.
    count = (len(data) - 20) // 4
    if struct.unpack_from("<I", data)[0] == SPIRV_MAGIC:
        return list(struct.unpack_from("<%dI" % count, data, 20))
    if struct.unpack_from(">I", data)[0] == SPIRV_MAGIC:
        return list(struct.unpack_from(">%dI" % count, data, 20))
    raise ValueError("bad SPIR-V magic")


def read_insts(data: bytes):
    stream = read_words(data)
    out, i = [], 0
    while i < len(stream):
        head = stream[i]
        count = head >> 16
        if count == 0:
            raise ValueError("zero-length instruction")
        out.append((head & 0xFFFF, stream[i + 1:i + count]))
        i += count
    return out


def read_string(operands: list[int]) -> str:
    raw = struct.pack("<%dI" % len(operands), *operands)
    end = raw.find(b"\0")
    return raw[:end if end >= 0 else len(raw)].decode("utf-8", "replace")


class Module:
    def __init__(self, data: bytes):
        self.names: dict[int, str] = {}
        self.member_names: dict[tuple[int, int], str] = {}
        self.decorations: dict[tuple, int] = {}
        self.types: dict[int, tuple[str, list[int]]] = {}
        self.constants: dict[int, int] = {}
        self.structs: dict[int, list[int]] = {}
        self.variables: list[tuple[str, int, int]] = []  # storage, id, type
        self.entry_points: list[tuple[str, list[int]]] = []
        for opcode, ops in read_insts(data):
            if opcode == 5 and ops:
                self.names[ops[0]] = read_string(ops[1:])
            elif opcode == 6 and len(ops) >= 2:
                self.member_names[(ops[0], ops[1])] = read_string(ops[2:])
            elif opcode == 71 and len(ops) >= 2:
                self.decorations[("dec", ops[0], ops[1])] = ops[2] if len(ops) > 2 else 1
            elif opcode == 72 and len(ops) >= 3:
                self.decorations[("mem", ops[0], ops[1], ops[2])] = ops[3] if len(ops) > 3 else 1
            elif opcode == 43 and len(ops) >= 3:
                self.constants[ops[1]] = ops[2]
            elif opcode in TYPE_OPCODES:
                self.types[ops[0]] = (OP_NAME[opcode], ops[1:])
                if opcode == 30:
                    self.structs[ops[0]] = list(ops[1:])
            elif opcode == 59 and len(ops) >= 3:
                # OpVariable: <result type> <result id> <storage class>
                self.variables.append((STORAGE_CLASS.get(ops[2], str(ops[2])), ops[1], ops[0]))
            elif opcode == 15 and len(ops) >= 3:
                self.entry_points.append((read_string(ops[2:]), list(ops[3:])))

    def ty(self, tid: int) -> str:
        kind, ops = self.types.get(tid, (None, []))
        if kind == "OpTypeFloat":
            return "float%d" % (32 if ops[0] == 0 else 64)
        if kind == "OpTypeInt":
            return ("int%d" if ops[0] == 1 else "uint%d") % ops[1]
        if kind == "OpTypeVector":
            return "vec%d<%s>" % (self.constants.get(ops[1], ops[1]), self.ty(ops[0]))
        if kind == "OpTypeMatrix":
            return "mat%d<%s>" % (self.constants.get(ops[1], ops[1]), self.ty(ops[0]))
        if kind == "OpTypeArray":
            return "%s[%d]" % (self.ty(ops[0]), self.constants.get(ops[1], ops[1]))
        if kind == "OpTypeRuntimeArray":
            return "%s[]" % self.ty(ops[0])
        if kind == "OpTypePointer":
            return "%s*" % self.ty(ops[1])
        if kind == "OpTypeStruct":
            return "struct#%d" % tid
        if kind == "OpTypeVoid":
            return "void"
        return "?%d" % (tid,)

    def describe(self, path: Path) -> None:
        data = path.read_bytes()
        print("== %s (%d bytes)" % (path.name, len(data)))
        for name, iface in self.entry_points:
            print("   entry %s" % name)
        for storage, vid, tid in self.variables:
            if storage not in ("Uniform", "UniformConstant", "PushConstant", "StorageBuffer"):
                continue
            kind, ops = self.types.get(tid, (None, []))
            if kind != "OpTypePointer":
                continue
            pointee = ops[1]
            if pointee in self.structs:
                member_types = self.structs[pointee]
                blocked = self.decorations.get(("dec", pointee, 2)) is not None or \
                    self.decorations.get(("dec", pointee, 4)) is not None
                if not blocked:
                    continue
                size = 0
                rows = []
                for index, mtype in enumerate(member_types):
                    offset = self.decorations.get(("mem", pointee, index, OFFSET))
                    label = self.member_names.get((pointee, index), "m%d" % index)
                    stride = self.decorations.get(("dec", mtype, 6))
                    text = self.ty(mtype)
                    if stride is not None:
                        text += "[stride %d]" % stride
                    rows.append((offset, label, text))
                    if offset is not None:
                        size = max(size, offset)
                dset = self.decorations.get(("dec", tid, DESCRIPTOR_SET))
                binding = self.decorations.get(("dec", tid, BINDING))
                print("   block %-22s storage=%-14s set=%s binding=%s minSize>=%d" %
                      (self.names.get(pointee, "?"), storage, dset, binding, size))
                for offset, label, text in rows:
                    print("       +%-5s %-22s %s" % ("?" if offset is None else offset, label, text))
            else:
                dset = self.decorations.get(("dec", tid, DESCRIPTOR_SET))
                binding = self.decorations.get(("dec", tid, BINDING))
                print("   %-30s storage=%-14s set=%s binding=%s" %
                      (self.ty(pointee), storage, dset, binding))
        print()


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: spv_layout_dump.py <file.spv> [...]", file=sys.stderr)
        return 2
    for name in argv[1:]:
        Module(Path(name).read_bytes()).describe(Path(name))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))