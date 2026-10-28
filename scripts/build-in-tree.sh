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

echo "== pack"
gzip -9 -n -c "$OUT_ABS/u-boot-nodtb.bin" > "$OUT_ABS/u-boot-nodtb.bin.gz"
cat "$OUT_ABS/u-boot-nodtb.bin.gz" "$DTB" > "$OUT_ABS/uboot-payload"

# Two layouts: with the stock DTB table (what the shim on this board is packed
# with) and without it (what the Mi 8 SE port boots). ABL behaviour on this
# handset is not documented, so both are shipped and tested one after the other.
python3 "$ROOT/scripts/pack-boot.py" "$OUT_ABS/uboot-payload" -o "$OUT_ABS/boot.img"
python3 "$ROOT/scripts/pack-boot.py" "$OUT_ABS/uboot-payload" --no-stock-dtbs \
        -o "$OUT_ABS/boot-nodtbs.img"

ls -l "$OUT_ABS/boot.img" "$OUT_ABS/boot-nodtbs.img" "$DTB" "$OUT_ABS/u-boot-nodtb.bin"
