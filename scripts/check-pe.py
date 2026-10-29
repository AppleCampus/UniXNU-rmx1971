#!/usr/bin/env python3
"""Fail unless the file is a PE32+ aarch64 image.

    check-pe.py <file> [<file> ...]

EDK II produces the right thing when the toolchain is wired up correctly, and a
subtly wrong thing (x86 image, missing PE header) when it is not. That failure
is invisible until the handset reboots with a blank screen, so check it here.
"""
import struct
import sys

status = 0
for path in sys.argv[1:]:
    try:
        blob = open(path, "rb").read()
    except OSError as exc:
        print(f"error: {path}: {exc}", file=sys.stderr)
        status = 1
        continue
    if blob[:2] != b"MZ":
        print(f"error: {path}: no MZ header", file=sys.stderr)
        status = 1
        continue
    pe = struct.unpack_from("<I", blob, 0x3C)[0]
    if blob[pe:pe + 4] != b"PE\0\0":
        print(f"error: {path}: no PE signature", file=sys.stderr)
        status = 1
        continue
    machine, sections = struct.unpack_from("<HH", blob, pe + 4)
    magic = struct.unpack_from("<H", blob, pe + 24)[0]
    if machine != 0xAA64 or magic != 0x20B:
        print(f"error: {path}: machine {machine:#x} magic {magic:#x}, "
              f"expected aarch64 PE32+", file=sys.stderr)
        status = 1
        continue
    print(f"{path}: {len(blob)} bytes, PE32+ aarch64, {sections} sections")

sys.exit(status)
