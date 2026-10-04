#!/usr/bin/env python3
"""The two BLPs the desktop log reported, read out of the vanilla 3.3.5a data.

The regression test that guards this is tools/tests/blp_mip_chain_test.cpp, which
rebuilds both headers and needs no game data. This one runs the same assertions
against the bytes as shipped, so the claim "these two files have a short tail"
is checked against the files themselves rather than against a transcription of
their headers.

Needs StormLib and the built libstorm.a, both of which the desktop build already
produces, plus the client archives. Pass the data directory as the only
argument; the default is the location this client is developed against.

Run: python wowee/tools/tests/blp_vanilla_mip_chain_check.py [dataDir]
"""
from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DATA = "/mnt/c/Users/josho/Games/ChromieCraft/ChromieCraft_3.3.5a/Data"

# The two files build-desktop/bin/logs/wowps.log reported, with the level
# geometry that each one's chain reaches.
TARGETS = [
    ("World\\Generic\\Orc\\Passive Doodads\\Bones\\Bone02.blp", 128, 32, 8),
    ("World\\Generic\\Human\\Passive Doodads\\CaveminePump\\Lever3.blp", 16, 64, 8),
]

EXTRACTOR_SOURCE = r"""
#include <StormLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv) {
    /* argv[1] = archive, argv[2] = name inside it, argv[3] = where to write */
    if (argc != 4) return 2;
    HANDLE a = NULL;
    if (!SFileOpenArchive(argv[1], 0, MPQ_OPEN_READ_ONLY | MPQ_OPEN_NO_LISTFILE | MPQ_OPEN_NO_ATTRIBUTES, &a))
        return 3;
    HANDLE f = NULL;
    if (!SFileOpenFileEx(a, argv[2], SFILE_OPEN_FROM_MPQ, &f)) { SFileCloseArchive(a); return 4; }
    DWORD size = SFileGetFileSize(f, NULL);
    void* buf = malloc(size ? size : 1);
    DWORD got = 0;
    if (size && !SFileReadFile(f, buf, size, &got, NULL)) { SFileCloseFile(f); SFileCloseArchive(a); return 5; }
    SFileCloseFile(f);
    SFileCloseArchive(a);
    FILE* out = fopen(argv[3], "wb");
    if (!out) { free(buf); return 6; }
    fwrite(buf, 1, got, out);
    fclose(out);
    free(buf);
    return 0;
}
"""


def find_stormlib() -> tuple[Path, Path]:
    """The StormLib headers and the archive library the desktop build links."""
    include = ROOT / "extern/StormLib/src"
    if not (include / "StormLib.h").is_file():
        raise AssertionError(f"no StormLib headers at {include}")
    for candidate in [ROOT.parent / "build-desktop/lib/libstorm.a",
                      ROOT.parent / "build-switch/lib/libstorm.a"]:
        if candidate.is_file():
            return include, candidate
    raise AssertionError("no libstorm.a; build the desktop target first")


def build_extractor(include: Path, storm: Path, out: Path) -> None:
    source = out.with_suffix(".c")
    source.write_text(EXTRACTOR_SOURCE, encoding="utf-8")
    try:
        subprocess.run(["cc", "-O1", "-o", str(out), str(source), f"-I{include}", str(storm),
                        "-lpthread", "-ldl", "-lz", "-lbz2", "-llzma", "-lcrypt", "-lstdc++"],
                       check=True)
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        raise AssertionError(
            f"could not build the StormLib extractor ({error}); this check needs a C compiler "
            "and the zlib, bzip2 and lzma development libraries StormLib links against")


def read_blp(extract: Path, data_dir: Path, name: str, dest: Path) -> bytes:
    """Pull one file out of the archives, highest priority first."""
    archives = ["patch-3.MPQ", "patch-2.MPQ", "patch.MPQ", "expansion.MPQ",
                "lichking.MPQ", "common-2.MPQ", "common.MPQ"]
    for archive in archives:
        path = data_dir / archive
        if not path.is_file():
            continue
        result = subprocess.run([str(extract), str(path), name, str(dest)])
        if result.returncode == 0:
            return dest.read_bytes()
    raise AssertionError(f"{name} is in none of the archives under {data_dir}")


def parse_blp2(raw: bytes) -> dict:
    if raw[:4] != b"BLP2":
        raise AssertionError(f"expected a BLP2, got {raw[:4]!r}")
    compression, alpha_depth, alpha_encoding, has_mips = struct.unpack_from("<BBBB", raw, 8)
    width, height = struct.unpack_from("<II", raw, 12)
    offsets = struct.unpack_from("<16I", raw, 20)
    sizes = struct.unpack_from("<16I", raw, 84)
    if compression == 2:
        block = 8 if (alpha_depth == 0 or alpha_encoding == 0) else 16
    else:
        block = 4
    levels = []
    w, h = width, height
    for index in range(16):
        if sizes[index] == 0:
            break
        need = ((w + 3) // 4 if block in (8, 16) else w) * \
               ((h + 3) // 4 if block in (8, 16) else h) * block
        levels.append({"index": index, "offset": offsets[index], "size": sizes[index],
                       "w": w, "h": h, "need": need, "short": sizes[index] < need})
        w, h = max(1, w // 2), max(1, h // 2)
    return {"width": width, "height": height, "compression": compression,
            "alpha_depth": alpha_depth, "alpha_encoding": alpha_encoding,
            "has_mips": has_mips, "block": block, "levels": levels, "size": len(raw)}


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    data_dir = Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DATA)
    if not data_dir.is_dir():
        print(f"SKIP vanilla BLP mip chain: {data_dir} is not a directory", file=sys.stderr)
        return 0

    include, storm = find_stormlib()
    with tempfile.TemporaryDirectory() as tmp:
        extract = Path(tmp) / "extract"
        build_extractor(include, storm, extract)
        for name, width, height, block in TARGETS:
            raw = read_blp(extract, data_dir, name, Path(tmp) / "file.blp")
            blp = parse_blp2(raw)
            short = [level for level in blp["levels"] if level["short"]]

            print(f"{name}")
            print(f"  {blp['size']} bytes, BLP2 comp={blp['compression']} "
                  f"alphaDepth={blp['alpha_depth']} alphaEnc={blp['alpha_encoding']} "
                  f"hasMips={blp['has_mips']}, {blp['width']}x{blp['height']}")
            for level in blp["levels"]:
                flag = "  SHORT" if level["short"] else ""
                print(f"    mip{level['index']} {level['w']}x{level['h']:<4} "
                      f"offset={level['offset']:<6} size={level['size']:<6} "
                      f"needs={level['need']}{flag}")

            check(blp["width"] == width and blp["height"] == height,
                  f"{name} is {blp['width']}x{blp['height']}, expected {width}x{height}")
            check(blp["compression"] == 2, f"{name} is not block-compressed")
            check(blp["has_mips"] == 1, f"{name} carries no mip chain")
            check(blp["block"] == block, f"{name} stores {blp['block']}-byte blocks")
            # The bug: a level the file cannot fill. One short level, and it is
            # not the first.
            check(short, f"{name} has no short level, so it does not reproduce the bug")
            check(short[0]["index"] > 0, f"{name}'s mip 0 is short, which is a different fault")
            # The fix: what the loader hands the GPU is the prefix above it, and
            # every level in that prefix covers its own extent.
            prefix = blp["levels"][:short[0]["index"]]
            check(all(not level["short"] for level in prefix),
                  f"{name} has a short level inside the prefix")
            check(len(prefix) >= 3, f"{name} keeps only {len(prefix)} level(s)")
            # A prefix of a halving chain is itself one, so it cannot exceed the
            # 16 the header has room for or go past 1x1.
            check(len(prefix) <= 16, f"{name} keeps more levels than the header holds")
            print(f"  first short level {short[0]['index']} ({short[0]['w']}x{short[0]['h']}): "
                  f"{short[0]['size']} B against {short[0]['need']} B needed; "
                  f"uploading {len(prefix)} complete level(s) "
                  f"({prefix[0]['size']} B base)")

    print("PASS vanilla BLP mip chains: both reported textures have a short tail, "
          "and every level above it covers its own extent")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as error:
        print(f"FAIL vanilla BLP mip chain: {error}", file=sys.stderr)
        sys.exit(1)
