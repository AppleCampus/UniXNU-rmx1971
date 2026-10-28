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

# The arm64 Image header in front of the payload has to say text_offset 0: this
# ABL computes a load address from that field, and 0 is what the working iOS
# payload on this handset carries (text_offset 0, code at +0x800, image_size =
# file size, flags 0xa). kconfig would produce it from CONFIG_TEXT_BASE minus
# CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE, but on a position-independent snapdragon
# build those defaults disagree (0 versus 0x80000000) and the result is
# -0x80000000 -- a load address 2 GiB below any RAM -- and neither a kconfig
# fragment nor scripts/config reliably overrides it. The two fields are pure
# data that nothing in U-Boot reads back, so rewrite them in the produced blob
# and fail the build if the result is not what the ABL is known to accept.
fix_image_header() {
	python3 - "$1" <<'PY'
import struct, sys

path = sys.argv[1]
blob = bytearray(open(path, "rb").read())
if len(blob) < 64 or blob[0x38:0x3c] != b"ARMd":
	sys.exit(f"error: {path} has no arm64 Image header")
struct.pack_into("<Q", blob, 0x08, 0)		# text_offset
struct.pack_into("<Q", blob, 0x10, len(blob))	# image_size
open(path, "wb").write(blob)

text_off, image_size, flags = struct.unpack_from("<QQQ", blob, 8)
if text_off != 0 or image_size != len(blob):
	sys.exit(f"error: {path}: text_offset {text_off:#x} image_size {image_size:#x}")
print(f"    image header: text_offset 0 image_size {image_size:#x} "
      f"flags {flags:#x} ({len(blob)} bytes)")
PY
}

echo "== pack"
fix_image_header "$OUT_ABS/u-boot-nodtb.bin"
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
fix_image_header "$PROBE_OUT/u-boot-nodtb.bin"
gzip -9 -n -c "$PROBE_OUT/u-boot-nodtb.bin" > "$PROBE_OUT/u-boot-nodtb.bin.gz"
python3 "$ROOT/scripts/pack-boot.py" "$PROBE_OUT/u-boot-nodtb.bin.gz" \
        --dtb-table "$OUT_ABS/stock-fb.bin" -o "$OUT_ABS/boot-probe.img"
ls -l "$OUT_ABS/boot-probe.img"
