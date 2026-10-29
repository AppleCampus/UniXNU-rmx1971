#!/usr/bin/env python3
"""Give the stock device tree a framebuffer node, so U-Boot has somewhere to draw.

Why this exists: this handset's ABL refuses a boot image whose appended DTB table
it cannot match, and the one DTB it reliably accepts is the vendor's own (that is
what the working iOS shim ships: gzip(payload) + the six stock DTBs, untouched).
Our hand-written board DTS matches on msm-id/board-id but the ABL still answered
`FAILED (remote: 'unknown command')`-style fall-through to fastboot, so we stop
arguing with it: patch the vendor DTB in place, keep every node it already has
(UFS, PMIC, clocks, GENI UART), and add the one thing Android never needed --
a simple-framebuffer pointing at the splash carve-out the ABL leaves behind.

Every DTB in the table is patched by default. That matters: the ABL picks one
entry by matching qcom,msm-id against the SoC it is running on, and nothing we
control says which one it takes. The vendor fills /memory with reg = <0 0 0 0> in
*all six* of them, so patching a single entry leaves U-Boot to panic on
"No valid memory ranges found!" whenever the ABL picks a different one -- and
that panic happens before the console exists, i.e. the handset just sits on the
splash forever with no way to reset itself.

Usage:
  patch-stock-dtb.py IN.bin OUT.bin [--index all|N] [--fb-base 0x9c000000]
                     [--fb-size 0x2300000] [--width 1080] [--height 2340]
                     [--stride 4320] [--format a8r8g8b8] [--bootargs TEXT]
"""

import argparse
import struct
import sys

FDT_MAGIC = b"\xd0\x0d\xfe\xed"
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


class Node:
    __slots__ = ("name", "props", "children")

    def __init__(self, name=""):
        self.name = name
        self.props = {}      # name -> raw value bytes
        self.children = []

    def child(self, name):
        for c in self.children:
            if c.name == name:
                return c
        return None

    def ensure(self, name):
        c = self.child(name)
        if c is None:
            c = Node(name)
            self.children.append(c)
        return c


def split_blob(blob):
    """Every FDT image in a concatenated table, in order."""
    out, i = [], 0
    while True:
        i = blob.find(FDT_MAGIC, i)
        if i < 0:
            return out
        size = struct.unpack(">I", blob[i + 4:i + 8])[0]
        if 0x100 < size <= len(blob) - i:
            out.append((i, size))
            i += size
        else:
            i += 4


def parse(dtb):
    magic, total, off_struct, off_str = struct.unpack(">4I", dtb[:16])
    if magic != 0xD00DFEED:
        raise ValueError("not an FDT")
    off_rsv = struct.unpack(">I", dtb[16:20])[0]

    def name_at(off):
        end = dtb.index(b"\0", off_str + off)
        return dtb[off_str + off:end].decode()

    root = Node()
    p, stack = off_struct, [root]
    while True:
        tag = struct.unpack(">I", dtb[p:p + 4])[0]
        if tag == FDT_BEGIN_NODE:
            end = dtb.index(b"\0", p + 4)
            node = Node(dtb[p + 4:end].decode(errors="replace"))
            stack[-1].children.append(node)
            stack.append(node)
            p = (end + 4) & ~3
        elif tag == FDT_END_NODE:
            stack.pop()
            p += 4
        elif tag == FDT_PROP:
            ln, nameoff = struct.unpack(">II", dtb[p + 4:p + 12])
            stack[-1].props[name_at(nameoff)] = dtb[p + 12:p + 12 + ln]
            p = (p + 12 + ln + 3) & ~3
        elif tag == FDT_NOP:
            p += 4
        elif tag == FDT_END:
            break
        else:
            raise ValueError(f"bad FDT tag {tag} at {p:#x}")
    rsv = dtb[off_rsv:off_struct]
    # `root` is the container the first FDT_BEGIN_NODE landed in; the real root
    # is that node, and it is the one that must be serialized again.
    return (root.children[0] if len(root.children) == 1 else root), rsv


def serialize(root, rsv):
    strings = bytearray()
    seen = {}

    def stri(name):
        if name not in seen:
            seen[name] = len(strings)
            strings.extend(name.encode() + b"\0")
        return seen[name]

    body = bytearray()

    def emit(node):
        body.extend(struct.pack(">I", FDT_BEGIN_NODE))
        raw = node.name.encode() + b"\0"
        body.extend(raw + b"\0" * ((-len(raw)) % 4))
        for name, val in node.props.items():
            body.extend(struct.pack(">III", FDT_PROP, len(val), stri(name)))
            body.extend(val + b"\0" * ((-len(val)) % 4))
        for c in node.children:
            emit(c)
        body.extend(struct.pack(">I", FDT_END_NODE))

    emit(root)
    body.extend(struct.pack(">I", FDT_END))

    off_rsv = 40
    off_struct = off_rsv + len(rsv)
    off_str = off_struct + len(body)
    total = off_str + len(strings)
    hdr = struct.pack(">10I", 0xD00DFEED, total, off_struct, off_str, off_rsv,
                      17, 16, 0, len(strings), len(body))
    return hdr + rsv + bytes(body) + bytes(strings)


def find_root(root):
    """`parse` returns a synthetic root; the real one is its first child."""
    if root.name == "" and len(root.children) == 1 and root.children[0].name == "":
        return root.children[0]
    return root


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--index", default="all",
                    help="which DTB of the table to patch: 'all' (default) or a "
                         "0-based index")
    ap.add_argument("--fb-base", default="0x9c000000")
    ap.add_argument("--fb-size", default="0x2300000")
    ap.add_argument("--width", type=int, default=1080)
    ap.add_argument("--height", type=int, default=2340)
    ap.add_argument("--stride", type=int, default=0)
    ap.add_argument("--format", default="a8r8g8b8")
    ap.add_argument("--mem-base", default="0x80000000")
    ap.add_argument("--mem-size", default="0x7e2c0000",
                    help="RAM window U-Boot is allowed to use (default: the low 1.97 GiB)")
    ap.add_argument("--bootargs", default="")
    a = ap.parse_args()

    blob = open(a.src, "rb").read()
    table = split_blob(blob)
    if not table:
        sys.exit(f"error: no FDT in {a.src}")
    if a.index == "all":
        targets = list(range(len(table)))
    else:
        targets = [int(a.index)]
        if targets[0] >= len(table):
            sys.exit(f"error: table has {len(table)} DTBs, index {a.index} is out of range")

    base = int(a.fb_base, 0)
    fbsize = int(a.fb_size, 0)
    stride = a.stride or a.width * 4

    def patch(off, size):
        root, rsv = parse(blob[off:off + size])
        rt = find_root(root)

        fb = rt.ensure(f"framebuffer@{base:x}")
        fb.props = {
            "compatible": b"simple-framebuffer\0",
            "status": b"okay\0",
            "reg": struct.pack(">IIII", 0, base, 0, fbsize),
            "width": struct.pack(">I", a.width),
            "height": struct.pack(">I", a.height),
            "stride": struct.pack(">I", stride),
            "format": a.format.encode() + b"\0",
        }

        chosen = rt.ensure("chosen")
        if a.bootargs:
            chosen.props["bootargs"] = a.bootargs.encode() + b"\0"
        else:
            chosen.props.pop("bootargs", None)

        # The vendor DTB carries `/memory` with reg = <0 0 0 0>: on Android the
        # kernel learns its RAM from SMEM instead, so the node was never filled
        # in. U-Boot does the opposite -- qcom_parse_memory() feeds this node to
        # gd->ram_base/ram_size and panics when it comes back empty -- so put a
        # window in it. The default is the low 1.97 GiB, the same window
        # ios-sweet hands to XNU: everything above 0x100000000 stays untouched,
        # and the splash carve-out at 0x9c000000 is already marked no-map in
        # reserved-memory, so U-Boot relocates to the top of the window instead
        # of landing on the framebuffer.
        mem = rt.ensure("memory")
        mem.props["device_type"] = b"memory\0"
        mem.props["reg"] = struct.pack(">IIII", 0, int(a.mem_base, 0), 0,
                                      int(a.mem_size, 0))

        return serialize(root, rsv)

    out = bytearray()
    for k, (o, s) in enumerate(table):
        if k in targets:
            patched = patch(o, s)
            if patched[:4] != FDT_MAGIC:
                sys.exit("error: serializer produced garbage")
            out.extend(patched)
            print(f"patched DTB #{k}: {s} -> {len(patched)} bytes")
        else:
            out.extend(blob[o:o + s])
            print(f"kept    DTB #{k}: {s} bytes")
    open(a.dst, "wb").write(out)
    print(f"table of {len(table)} -> {len(out)} bytes")
    print(f"framebuffer {base:#x} {a.width}x{a.height} stride {stride} {a.format}")
    print(f"memory @ {int(a.mem_base, 0):#x} size {int(a.mem_size, 0):#x}")


if __name__ == "__main__":
    main()
