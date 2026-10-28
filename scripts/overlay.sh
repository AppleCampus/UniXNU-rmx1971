#!/usr/bin/env bash
# Copy this repository's board files into a U-Boot checkout.
#   scripts/overlay.sh <u-boot checkout>
set -euo pipefail

UB=${1:-uboot}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[ -d "$UB/dts/upstream/src/arm64/qcom" ] || {
	echo "error: $UB is not a u-boot checkout with dts/upstream" >&2; exit 1; }

install -D -m 644 "$ROOT/dts/sdm710-realme-rmx1971.dts" \
	"$UB/dts/upstream/src/arm64/qcom/sdm710-realme-rmx1971.dts"
install -D -m 644 "$ROOT/board/realme/rmx1971/rmx1971.config" \
	"$UB/board/realme/rmx1971/rmx1971.config"
install -D -m 644 "$ROOT/board/realme/rmx1971/rmx1971.env" \
	"$UB/board/realme/rmx1971/rmx1971.env"

echo "overlaid rmx1971 board files into $UB"
