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

# The vendor's own DTB table, with two nodes added: a simple-framebuffer at the
# ABL splash address and a /memory window (the vendor node has reg = <0 0 0 0>
# because Android learns RAM from SMEM; U-Boot hangs on an empty one).
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
gzip -9 -n -c "$PROBE_OUT/u-boot-nodtb.bin" > "$PROBE_OUT/u-boot-nodtb.bin.gz"
python3 "$ROOT/scripts/pack-boot.py" "$PROBE_OUT/u-boot-nodtb.bin.gz" \
        --dtb-table "$OUT_ABS/stock-fb.bin" -o "$OUT_ABS/boot-probe.img"
ls -l "$OUT_ABS/boot-probe.img"
