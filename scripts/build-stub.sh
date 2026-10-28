#!/usr/bin/env bash
# Build the paint-fb stub as a boot image (the "did the ABL jump at all" probe).
#
#   scripts/build-stub.sh [out dir]
#
# Needs only an aarch64 cross toolchain -- no U-Boot checkout, no defconfig.
# The output uses the same container as the U-Boot images (gzip payload plus the
# patched vendor DTB table), so the only thing that differs is the payload.
set -euo pipefail

OUT=${1:-out-stub}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
mkdir -p "$OUT"

# -Ttext=0: the stub is position independent and never references a symbol by
# absolute address, so the link address only decides where the bytes start in
# the ELF. objcopy then yields a bare blob of a few hundred bytes.
"${CROSS}gcc" -nostdlib -nostartfiles -ffreestanding -Wl,--build-id=none \
	-Wl,-Ttext=0 -o "$OUT/paint-fb.elf" "$ROOT/stub/paint-fb.S"
"${CROSS}objcopy" -O binary "$OUT/paint-fb.elf" "$OUT/paint-fb.bin"
"${CROSS}objdump" -d "$OUT/paint-fb.elf" > "$OUT/paint-fb.dis"

# Same header contract as the U-Boot payload: text_offset 0, code at +0x800,
# total size padded to STUB_SIZE so the ABL sees the shape it already boots.
python3 - "$OUT/paint-fb.bin" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
text_off, image_size, flags = struct.unpack_from("<QQQ", b, 8)
if b[0x38:0x3c] != b"ARMd":
	sys.exit("error: stub has no arm64 Image header")
if text_off != 0:
	sys.exit(f"error: stub text_offset {text_off:#x} != 0")
if image_size != len(b):
	sys.exit(f"error: stub image_size {image_size:#x} != file size {len(b):#x}")
code0 = struct.unpack_from("<I", b, 0)[0]
if code0 != 0x14000200:
	sys.exit(f"error: code0 {code0:#x}, expected b #0x800 (0x14000200)")
print(f"    stub header ok: {len(b)} bytes, code at +0x800, text_offset 0")
PY

gzip -9 -n -c "$OUT/paint-fb.bin" > "$OUT/paint-fb.bin.gz"

python3 "$ROOT/scripts/patch-stock-dtb.py" "$ROOT/firmware/stock-appended-dtbs.bin" \
	"$OUT/stock-fb.bin"
python3 "$ROOT/scripts/pack-boot.py" "$OUT/paint-fb.bin.gz" \
	--dtb-table "$OUT/stock-fb.bin" -o "$OUT/boot-stub.img"

ls -l "$OUT/paint-fb.bin" "$OUT/paint-fb.bin.gz" "$OUT/boot-stub.img"
