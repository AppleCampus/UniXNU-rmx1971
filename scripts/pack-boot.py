#!/usr/bin/env python3
"""Pack a U-Boot payload into an Android boot image v1 for the Realme 5 Pro.

The image parameters are the ones the stock boot.img carries; ABL on this board
misloads anything that does not mirror them (see rmx1971-ios/board.toml, where
the same table was first written down).

Layout of the kernel field, as ABL expects it here:

    gzip(u-boot-nodtb.bin) + sdm710-realme-rmx1971.dtb + stock appended DTBs

U-Boot finds its own device tree right after the gzip stream; the stock DTB set
afterwards keeps `androidboot.dtb_idx=3` meaningful for ABL, which passes the
base FDT to us in x0 (U-Boot reads the memory map from it).

Usage: pack-boot.py PAYLOAD [-o boot.img] [--dtbs stock-appended-dtbs.bin]
"""

import argparse
import gzip
import hashlib
import os
import struct
import sys

BOARD = {
    "page_size": 4096,
    "kernel_addr": 0x8000,
    "ramdisk_addr": 0x1000000,
    "tags_addr": 0x100,
    "header_version": 1,
    "os_version": 0x200001A7,
    "cmdline": (
        "console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xA90000 "
        "androidboot.hardware=qcom androidboot.console=ttyMSM0 "
        "androidboot.dtb_idx=3 androidboot.serialno=rmx1971-uboot"
    ),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("payload", help="gzip(u-boot-nodtb.bin) + board dtb")
    ap.add_argument("-o", "--out", default="boot.img")
    ap.add_argument("--dtbs", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  "..", "firmware", "stock-appended-dtbs.bin"))
    a = ap.parse_args()

    b = BOARD
    payload = open(a.payload, "rb").read()
    if payload[:2] != b"\x1f\x8b":
        sys.exit("error: the payload must start with the gzip stream of u-boot-nodtb.bin")
    if b"\xd0\x0d\xfe\xed" not in payload:
        sys.exit("error: no FDT in the payload; append the board dtb after the gzip stream")

    dtbs = open(a.dtbs, "rb").read()
    if dtbs[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit(f"error: {a.dtbs} is not an FDT blob")
    kdata = payload + dtbs

    page = b["page_size"]
    hdr = bytearray(page)
    struct.pack_into("<8s", hdr, 0, b"ANDROID!")
    struct.pack_into("<10I", hdr, 8, len(kdata), b["kernel_addr"],
                     0, b["ramdisk_addr"], 0, 0,
                     b["tags_addr"], page, b["header_version"], b["os_version"])
    cmd = b["cmdline"].encode()[:511]
    hdr[64:64 + len(cmd)] = cmd
    sha = hashlib.sha1(bytes(hdr[:576]) + kdata + bytes(hdr[704:1728]))
    struct.pack_into("<32I", hdr, 576, *struct.unpack("<5I", sha.digest()), *([0] * 27))

    pad = lambda n: (n + page - 1) // page * page
    img = bytes(hdr) + kdata.ljust(pad(len(kdata)), b"\0")
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, "wb").write(img)
    print(f"boot image: {a.out} ({len(img)} bytes, kernel field {len(kdata)} bytes)")


if __name__ == "__main__":
    main()
