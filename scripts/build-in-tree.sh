#!/usr/bin/env bash
# Build U-Boot for the Realme 5 Pro and pack it into a boot image.
#
#   scripts/build-in-tree.sh <u-boot checkout> [out dir]
#
# Run from this repository's root, on a Linux host with an aarch64 cross
# toolchain (gcc-aarch64-linux-gnu). The checkout is used as-is; our board files
# are copied in by scripts/overlay.sh first.
set -euo pipefail

UB=${1:-uboot}
OUT=${2:-out}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_ABS=$(mkdir -p "$OUT" && cd "$OUT" && pwd)

cd "$UB"
echo "== defconfig"
# kconfig resolves a fragment by basename through `find board -name <target>`,
# so the path must not be passed here.
make -s O="$OUT_ABS" qcom_defconfig qcom-phone.config rmx1971.config

echo "== build"
make -s O="$OUT_ABS" -j"$(nproc)" \
     DEVICE_TREE=qcom/sdm710-realme-rmx1971 \
     CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

DTB="$OUT_ABS/dts/upstream/src/arm64/qcom/sdm710-realme-rmx1971.dtb"
[ -f "$DTB" ] || { echo "error: $DTB missing" >&2; exit 1; }
[ -f "$OUT_ABS/u-boot-nodtb.bin" ] || { echo "error: u-boot-nodtb.bin missing" >&2; exit 1; }

# The ABL on this handset reads the arm64 Image header in front of the payload
# and computes a load address from text_offset. U-Boot writes
# CONFIG_TEXT_BASE - CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE there, which with a
# position-independent build (TEXT_BASE 0) and the mach-snapdragon default base
# of 0x80000000 comes out as -0x80000000, i.e. 2 GiB below any RAM. That single
# field is the difference between the working iOS shim (text_offset 0) and a
# handset that sits on the splash forever, so fail the build rather than ship it.
check_header() {
	python3 - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read(64)
text_off, image_size, flags = struct.unpack_from("<QQQ", b, 8)
if b[0x38:0x3c] != b"ARMd":
	sys.exit(f"error: {sys.argv[1]} has no arm64 Image header")
if text_off != 0:
	sys.exit(f"error: text_offset {text_off & (2**64 - 1):#x} != 0 "
	         f"(set CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE=0x0); the ABL would "
	         f"load the payload below RAM")
print(f"    image header ok: text_offset 0 image_size {image_size:#x} flags {flags:#x}")
PY
}
check_header "$OUT_ABS/u-boot-nodtb.bin"

echo "== pack"
gzip -9 -n -c "$OUT_ABS/u-boot-nodtb.bin" > "$OUT_ABS/u-boot-nodtb.bin.gz"

# The vendor's own DTB table, with two nodes added to *every* entry: a
# simple-framebuffer at the ABL splash address and a /memory window (the vendor
# nodes all have reg = <0 0 0 0> because Android learns RAM from SMEM; U-Boot
# panics on an empty one, before the console exists, which looks exactly like a
# dead handset on the splash).
#
# This is the layout the working iOS shim on this handset uses -- gzip(payload)
# followed by the six stock DTBs, nothing else -- and it is the only one this
# ABL has ever accepted: a hand-written board DTB as the sole table entry falls
# straight through to fastboot, and board DTB + stock table stops on the logo.
python3 "$ROOT/scripts/patch-stock-dtb.py" "$ROOT/firmware/stock-appended-dtbs.bin" \
        "$OUT_ABS/stock-fb.bin"
python3 "$ROOT/scripts/pack-boot.py" "$OUT_ABS/u-boot-nodtb.bin.gz" \
        --dtb-table "$OUT_ABS/stock-fb.bin" -o "$OUT_ABS/boot.img"

# Kept for the record: the board DTB ahead of the stock table. Stops on the
# realme logo (the board DTB wins the match and U-Boot has no /memory there).
python3 - "$OUT_ABS/u-boot-nodtb.bin.gz" "$DTB" "$OUT_ABS/uboot-payload" <<'PY'
import sys
open(sys.argv[3], 'wb').write(open(sys.argv[1], 'rb').read() + open(sys.argv[2], 'rb').read())
PY
python3 "$ROOT/scripts/pack-boot.py" "$OUT_ABS/uboot-payload" -o "$OUT_ABS/boot-boarddtb.img"

ls -l "$OUT_ABS/boot.img" "$OUT_ABS/boot-boarddtb.img" "$OUT_ABS/stock-fb.bin" \
      "$DTB" "$OUT_ABS/u-boot-nodtb.bin"

# ---------------------------------------------------------------------------
# Second pass: the same payload, but with a default environment that proves the
# CPU is executing U-Boot without needing the display. The environment is
# compiled into the binary (CONFIG_ENV_DEFAULT_ENV_TEXT_FILE), so this needs its
# own build directory rather than an env change at run time.
PROBE_OUT="$(dirname "$OUT_ABS")/out-probe"
echo "== build probe ($PROBE_OUT)"
make -s O="$PROBE_OUT" qcom_defconfig qcom-phone.config rmx1971.config
bash ./scripts/config --file "$PROBE_OUT/.config" --set-str ENV_DEFAULT_ENV_TEXT_FILE \
     board/realme/rmx1971/rmx1971-probe.env
make -s O="$PROBE_OUT" olddefconfig
make -s O="$PROBE_OUT" -j"$(nproc)" \
     DEVICE_TREE=qcom/sdm710-realme-rmx1971 \
     CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
grep -q "rmx1971-probe.env" "$PROBE_OUT/include/generated/autoconf.h" \
    || { echo "error: probe env did not take effect" >&2; exit 1; }
check_header "$PROBE_OUT/u-boot-nodtb.bin"
gzip -9 -n -c "$PROBE_OUT/u-boot-nodtb.bin" > "$PROBE_OUT/u-boot-nodtb.bin.gz"
python3 "$ROOT/scripts/pack-boot.py" "$PROBE_OUT/u-boot-nodtb.bin.gz" \
        --dtb-table "$OUT_ABS/stock-fb.bin" -o "$OUT_ABS/boot-probe.img"
ls -l "$OUT_ABS/boot-probe.img"
