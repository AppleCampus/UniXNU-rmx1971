#!/usr/bin/env python3
"""Print the arm64 Image header fields of one or more payloads.

The ABL on this handset reads `text_offset` from this header and computes a load
address from it, so the field is worth seeing without flashing anything: report
it in the CI summary next to every build.

Usage: report-header.py PAYLOAD [PAYLOAD...]
"""

import struct
import sys

for path in sys.argv[1:]:
    blob = open(path, "rb").read(64)
    if len(blob) < 64 or blob[0x38:0x3C] != b"ARMd":
        print(f"{path}: no arm64 Image header")
        continue
    text_off, image_size, flags = struct.unpack_from("<QQQ", blob, 8)
    print(f"{path}: text_offset {text_off & (2**64 - 1):#x} "
          f"image_size {image_size:#x} flags {flags:#x}")
