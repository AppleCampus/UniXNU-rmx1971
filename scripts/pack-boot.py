#!/usr/bin/env python3
"""Pack a U-Boot payload into an Android boot image v1 for the Realme 5 Pro.

The image parameters are the ones the stock boot.img carries; ABL on this board
misloads anything that does not mirror them (see rmx1971-ios/board.toml, where
the same table was first written down).

Layout of the kernel field:

    gzip(u-boot-nodtb.bin) + <DTB table>

The default table is the vendor's own six DTBs, which is what the working iOS
image on this handset carries and the only table this ABL is known to accept:

  --dtb-table FILE   append FILE verbatim (patch-stock-dtb.py output: the vendor
                     table with a framebuffer node and a /memory window added)
  --no-stock-dtbs    payload as-is, board DTB only, no dtb_idx (drops to fastboot
                     on this board, kept for experiments)
  default            board DTB + the vendor table, cmdline says dtb_idx=3

Usage: pack-boot.py PAYLOAD [-o boot.img] [--dtb-table FILE]
                            [--dtbs stock-appended-dtbs.bin] [--no-stock-dtbs]
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
    ap.add_argument("--no-stock-dtbs", action="store_true",
                    help="board dtb only, and drop androidboot.dtb_idx from the cmdline")
    ap.add_argument("--dtb-table",
                    help="append this FDT table (the vendor's own, optionally patched by "
                         "patch-stock-dtb.py) instead of the board dtb + stock table; the "
                         "payload may then be the bare gzip stream")
    a = ap.parse_args()

    b = dict(BOARD)
    if a.no_stock_dtbs or a.dtb_table:
        b["cmdline"] = b["cmdline"].replace(" androidboot.dtb_idx=3", "")
    payload = open(a.payload, "rb").read()
    if payload[:2] != b"\x1f\x8b":
        sys.exit("error: the payload must start with the gzip stream of u-boot-nodtb.bin")
    if not a.dtb_table and b"\xd0\x0d\xfe\xed" not in payload:
        sys.exit("error: no FDT in the payload; append the board dtb after the gzip stream")

    if a.dtb_table:
        table = open(a.dtb_table, "rb").read()
        if table[:4] != b"\xd0\x0d\xfe\xed":
            sys.exit(f"error: {a.dtb_table} is not an FDT blob")
        kdata = payload + table
    elif a.no_stock_dtbs:
        kdata = payload
    else:
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
