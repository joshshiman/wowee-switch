#!/usr/bin/env python3
"""Generate the nxvk Vulkan loader trampolines.

nvxk (Mesa's NVK driver ported to the Switch) exports exactly one symbol,
vk_icdGetInstanceProcAddr. The renderer, however, is written against the
plain Vulkan API and calls entry points directly (that is how the PS4 port
worked with its vendored ICD, which exported them itself).

This script reads the real Vulkan headers and emits one forwarding function
per directly-called entry point:

    static PFN_vkCreateBuffer fn;
    if (!fn) fn = (PFN_vkCreateBuffer)vk_nxvkLoadDeviceProc(device, "vkCreateBuffer");
    return fn(device, ...);

Device-level functions (first argument is a VkDevice/VkQueue/VkCommandBuffer)
resolve through the driver's vkGetDeviceProcAddr for that device; instance
and global functions resolve through vk_icdGetInstanceProcAddr.

Usage:
    python tools/switch/gen_nxvk_loader.py \
        --headers references/nxvk/include/vulkan \
        --out wowee/src/platform/switch/vk_nxvk_loader.inc \
        vkCreateBuffer vkCreateDevice ...
"""

import argparse
import os
import re
import sys

DECL_RE = re.compile(
    r"VKAPI_ATTR\s+(?P<ret>[\w\s]+?)\s+VKAPI_CALL\s+(?P<name>vk\w+)\s*\((?P<params>.*?)\);",
    re.S,
)

INSTANCE_FIRST = (
    "VkInstance",
    "VkPhysicalDevice",
    "VkAllocationCallbacks*",
)


def parse_params(params_text: str):
    """Split a Vulkan prototype's parameter list into (type, name) pairs."""
    params = []
    depth = 0
    current = ""
    for ch in params_text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            params.append(current)
            current = ""
        else:
            current += ch
    if current.strip():
        params.append(current)

    parsed = []
    for raw in params:
        decl = re.sub(r"/\*.*?\*/", " ", raw, flags=re.S)  # strip comments
        decl = re.sub(r"\s+", " ", decl).strip()
        if not decl or decl == "void":
            continue
        if "[" in decl:  # arrays are not used by these entry points
            raise ValueError("array parameter: %r" % decl)
        match = re.search(r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)$", decl)
        if not match:
            raise ValueError("cannot find parameter name in %r" % decl)
        name = match.group("name")
        ctype = decl[: match.start()].strip()
        parsed.append((ctype, name))
    return parsed


def load_declarations(header_dirs):
    """name -> (return type, [(type, name), ...]) for every entry point found."""
    decls = {}
    for header_dir in header_dirs:
        for entry in sorted(os.listdir(header_dir)):
            if not entry.endswith(".h"):
                continue
            with open(os.path.join(header_dir, entry), "r", encoding="utf-8") as handle:
                text = handle.read()
            for match in DECL_RE.finditer(text):
                name = match.group("name")
                try:
                    params = parse_params(match.group("params"))
                except ValueError:
                    # e.g. an array parameter: not used by any entry point the
                    # client calls directly, so leave it ungenerated.
                    continue
                decls[name] = (match.group("ret").strip(), params)
    return decls


def emit(name, ret, params, out):
    args = ", ".join("%s %s" % (t, n) for t, n in params)
    call_args = ", ".join(n for _, n in params)
    first_type = params[0][0] if params else ""
    # Only VkDevice-first entry points must go through the driver's
    # vkGetDeviceProcAddr for that device. Everything else (global,
    # instance-, physical-device-, queue- and command-buffer-level) is in the
    # instance dispatch table, which vk_icdGetInstanceProcAddr returns for a
    # valid instance.
    device_level = first_type.startswith("VkDevice")

    out.append("VKAPI_ATTR %s VKAPI_CALL %s(%s) {" % (ret, name, args))
    out.append("    static PFN_%s fn = nullptr;" % name)
    out.append("    if (!fn) {")
    if device_level:
        out.append('        fn = reinterpret_cast<PFN_%s>('
                   'vk_nxvkLoadDeviceProc(%s, "%s"));' % (name, params[0][1], name))
    else:
        out.append('        fn = reinterpret_cast<PFN_%s>('
                   'vk_nxvkLoadInstanceProc("%s"));' % (name, name))
    out.append("    }")
    out.append('    if (!fn) vk_nxvkMissingEntryPoint("%s");' % name)
    out.append("    return fn(%s);" % call_args)
    out.append("}")
    out.append("")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--headers", required=True, nargs="+")
    parser.add_argument("--out", required=True)
    parser.add_argument("functions", nargs="+")
    args = parser.parse_args()

    decls = load_declarations(args.headers)
    missing = [f for f in args.functions if f not in decls]
    if missing:
        print("missing declarations: %s" % ", ".join(missing), file=sys.stderr)
        return 1

    out = [
        "// Generated by tools/switch/gen_nxvk_loader.py - do not edit.",
        "// Forwarding trampolines from the plain Vulkan API into nxvk's single",
        "// vk_icdGetInstanceProcAddr entry point.",
        "",
    ]
    for name in args.functions:
        ret, params = decls[name]
        emit(name, ret, params, out)

    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())