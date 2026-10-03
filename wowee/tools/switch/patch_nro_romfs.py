#!/usr/bin/env python3
"""Record an appended romfs in an NRO header, which elf2nro does not do.

`elf2nro --romfs=<image>` writes the romfs after the NRO image but leaves the
header's romfs fields zeroed, so libnx never finds it. libnx's romfsMountSelf
does not read the fields out of the loaded image: for an NRO it opens the file
named by argv[0], reads 16 bytes at file offset 0x70, and treats them as
{u64 romfs_offset, u64 romfs_size}. Those are the two words patched here.

    patch_nro_romfs.py <nro> <romfs-image>

The romfs is located by seeking to the end of the image: the NRO body is
everything before it, and the image is the whole remainder.
"""
import struct
import sys

ROMFS_OFFSET_FIELD = 0x70  # u64
ROMFS_SIZE_FIELD = 0x78    # u64


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    nro_path, image_path = argv[1], argv[2]

    with open(nro_path, "rb") as f:
        nro = f.read()
    with open(image_path, "rb") as f:
        image = f.read()
    if not image:
        print(f"error: {image_path} is empty")
        return 1

    # The image is what elf2nro appended, so it starts where the NRO body ends.
    # Search rather than assume: a header patch must not depend on elf2nro's
    # exact padding.
    start = nro.rfind(image[:64])
    if start < 0 or start + len(image) != len(nro):
        print(f"error: {image_path} is not appended to {nro_path}")
        return 1

    nro = bytearray(nro)
    struct.pack_into("<Q", nro, ROMFS_OFFSET_FIELD, start)
    struct.pack_into("<Q", nro, ROMFS_SIZE_FIELD, len(image))
    with open(nro_path, "wb") as f:
        f.write(nro)

    print(f"patched {nro_path}: romfs at {start} + {len(image)} bytes "
          f"(fields 0x{ROMFS_OFFSET_FIELD:x}/0x{ROMFS_SIZE_FIELD:x})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))