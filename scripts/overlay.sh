#!/usr/bin/env bash
# Copy this repository's board files into a U-Boot checkout, then apply the
# source patches this board needs.
#   scripts/overlay.sh <u-boot checkout>
set -euo pipefail

UB=${1:-uboot}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[ -d "$UB/dts/upstream/src/arm64/qcom" ] || {
	echo "error: $UB is not a u-boot checkout with dts/upstream" >&2; exit 1; }

install -D -m 644 "$ROOT/dts/sdm710-realme-rmx1971.dts" \
	"$UB/dts/upstream/src/arm64/qcom/sdm710-realme-rmx1971.dts"
# Board files: the kconfig fragment and every environment variant (rmx1971.env
# for the real image, rmx1971-probe.env for the proof-of-life one).
for f in "$ROOT"/board/realme/rmx1971/*; do
	install -D -m 644 "$f" "$UB/board/realme/rmx1971/$(basename "$f")"
done

echo "overlaid rmx1971 board files into $UB"

# Source patches. `patch` rather than `git apply` so the build survives small
# context drift on the upstream branch; every patch is a couple of lines with a
# long explanation, so a rejected hunk means the tree moved, not that the fix is
# optional.
for p in "$ROOT"/patches/uboot/*.patch; do
	[ -e "$p" ] || continue
	echo "applying $(basename "$p")"
	patch -p1 -d "$UB" --batch --forward --no-backup-if-mismatch < "$p"
done

# The build still succeeds with the UFS gate missing -- it only fails at run
# time, on a screen nobody can type at -- so check the text actually landed.
grep -q 'GCC_UFS_PHY_RX_SYMBOL_1_CLK,		0x770a8' \
	"$UB/drivers/clk/qcom/clock-sdm845.c" || {
	echo "error: UFS PHY RX lane 1 clock patch did not apply" >&2; exit 1; }

echo "patched $UB"
