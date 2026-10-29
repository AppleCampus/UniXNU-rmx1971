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
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
DEVICE_TREE=${DEVICE_TREE:-qcom/sdm710-realme-rmx1971}
DTB_REL="dts/${DTB_SUBDIR:-upstream/src/arm64/qcom}/sdm710-realme-rmx1971.dtb"

build() { # $1 = build dir
	make -s O="$1" -j"$(nproc)" DEVICE_TREE="$DEVICE_TREE" CROSS_COMPILE="$CROSS"
}

# kconfig silently drops a symbol whose dependencies are not met, and most of
# what this board needs (partition tables, FAT) is not selected by qcom_defconfig
# at all. Without this check the build stays green and the handset boots into a
# U-Boot that answers "Unknown command 'part'" -- one wasted flash cycle per
# missing symbol.
require_config() { # $1 = build dir, $2.. = symbols that must end up 'y'
	local dir=$1 sym
	shift
	for sym in "$@"; do
		grep -qx "CONFIG_${sym}=y" "$dir/.config" || {
			echo "error: CONFIG_$sym missing from $dir/.config" >&2
			exit 1
		}
	done
	echo "    required config ok: $*"
}

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

# Build the payload: u-boot-nodtb.bin followed by our board DTB, gzipped.
#
# With CONFIG_OF_SEPARATE, fdtdec_setup() takes the devicetree from _end --
# fdt_find_separate() returns exactly that -- and only then lets the board
# override it. Appending the DTB is what makes _end a valid blob, so U-Boot
# reads its own tree and stops depending on what the ABL passes in x0. That
# mattered: with a nodtb-only payload the internal blob is absent, so
# board_fdt_blob_setup() needs the external FDT to be valid, and when it is not
# it panics with "Internal FDT is invalid and no external FDT was provided!"
# before the console exists -- with CONFIG_PANIC_HANG that is a handset sitting
# on the ABL splash, no output, no reset, indistinguishable from a CPU that
# never started.
#
# _end is the byte after the last section, i.e. u-boot-nodtb.bin's length, so
# the DTB goes at that exact offset: no padding, no page alignment.
make_payload() { # $1 = build dir, $2 = output .gz
	local dir=$1 out=$2
	local nodtb="$dir/u-boot-nodtb.bin" dtb="$dir/$DTB_REL"
	local bin="$dir/u-boot+dtb.bin"

	[ -f "$nodtb" ] || { echo "error: $nodtb missing" >&2; exit 1; }
	[ -f "$dtb" ]   || { echo "error: $dtb missing" >&2; exit 1; }

	cat "$nodtb" "$dtb" > "$bin"

	python3 - "$bin" "$nodtb" "$ROOT" <<'PY'
import struct, sys

binpath, nodtb, root = sys.argv[1], sys.argv[2], sys.argv[3]
off = len(open(nodtb, "rb").read())
blob = open(binpath, "rb").read()

if blob[off:off + 4] != b"\xd0\x0d\xfe\xed":
	sys.exit(f"error: no FDT at _end ({off:#x}) in {binpath}")
tot = struct.unpack_from(">I", blob, off + 4)[0]
if tot < 0x100 or off + tot > len(blob):
	sys.exit(f"error: DTB at {off:#x} claims {tot} bytes, "
	         f"{len(blob) - off} present")
print(f"    dtb at _end: {off:#x}, {tot} bytes, {len(blob)} total")

# Walk it with the same parser the vendor-DTB patcher uses: prove the node
# qcom_parse_memory() looks up is there, and that it carries a real window.
sys.path.insert(0, root + "/scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("p", root + "/scripts/patch-stock-dtb.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
dtb = blob[off:off + tot]
rt = m.find_root(m.parse(dtb)[0])
mem = rt.child("memory")
if mem is None:
	sys.exit(f"error: internal DT has no literal /memory node "
	         f"(children: {[c.name for c in rt.children][:12]})")
reg = mem.props.get("reg", b"")
if len(reg) != 16:
	sys.exit(f"error: /memory reg is {len(reg)} bytes, qcom_parse_memory() "
	         f"reads it as two 64-bit cells")
base, size = struct.unpack(">QQ", reg)
if not size:
	sys.exit("error: /memory has a zero size; qcom_parse_memory() would "
	         "return -ENODATA")
fb = [c for c in rt.children if c.name.startswith("framebuffer@")]
model = rt.props.get("model", b"").split(b"\0")[0].decode()
print(f"    internal DT ok: /memory {base:#x}+{size:#x}, "
      f"{len(fb)} framebuffer node(s), model {model!r}")
PY

	# Optional second opinion from the dtc the build just compiled: it is the
	# real libfdt-based parser, and it rejects layouts our own parser might
	# accept.
	local dtc=""
	for c in "$dir/scripts/dtc/dtc" "$(command -v dtc 2>/dev/null || true)"; do
		[ -n "$c" ] && [ -x "$c" ] && dtc=$c && break
	done
	if [ -n "$dtc" ]; then
		python3 -c 'import sys;d=open(sys.argv[1],"rb").read();o=len(open(sys.argv[2],"rb").read());open(sys.argv[3],"wb").write(d[o:])' \
			"$bin" "$nodtb" "$dir/u-boot.dtb.extracted"
		"$dtc" -I dtb -O dts -o "$dir/u-boot.dtb.extracted.dts" \
			"$dir/u-boot.dtb.extracted"
		grep -qE "^[[:space:]]*memory \{" "$dir/u-boot.dtb.extracted.dts" || {
			echo "error: dtc output has no /memory node" >&2; exit 1; }
		echo "    dtc parsed the internal DT ($(basename "$dtc"))"
	fi

	fix_image_header "$bin"
	gzip -9 -n -c "$bin" > "$out"
}

pack() { # $1 = gzipped payload, $2 = boot image
	python3 "$ROOT/scripts/pack-boot.py" "$1" --dtb-table "$OUT_ABS/stock-fb.bin" -o "$2"
}

cd "$UB"
echo "== defconfig"
# kconfig resolves a fragment by basename through `find board -name <target>`,
# so the path must not be passed here.
make -s O="$OUT_ABS" qcom_defconfig qcom-phone.config rmx1971.config
require_config "$OUT_ABS" EFI_PARTITION CMD_PART CMD_FAT FS_FAT CMD_FS_GENERIC \
	FASTBOOT_FLASH_BLOCK CMD_FASTBOOT USB_DWC3_GADGET FASTBOOT_OEM_RUN \
	FASTBOOT_CMD_OEM_CONSOLE CONSOLE_RECORD

echo "== build"
build "$OUT_ABS"

# The vendor's own DTB table, with two nodes added to *every* entry: a
# simple-framebuffer at the ABL splash address and a /memory window (the vendor
# nodes all have reg = <0 0 0 0> because Android learns RAM from SMEM).
#
# This is the layout the working iOS shim on this handset uses -- gzip(payload)
# followed by the six stock DTBs, nothing else -- and it is the only one this
# ABL has ever accepted: a hand-written board DTB as the sole table entry falls
# straight through to fastboot, and board DTB + stock table stops on the logo.
# The table is for the ABL, not for U-Boot: U-Boot now carries its own DTB
# inside the gzip.
python3 "$ROOT/scripts/patch-stock-dtb.py" "$ROOT/firmware/stock-appended-dtbs.bin" \
        "$OUT_ABS/stock-fb.bin"

echo "== pack"
make_payload "$OUT_ABS" "$OUT_ABS/payload.gz"
pack "$OUT_ABS/payload.gz" "$OUT_ABS/boot.img"

# Kept for the record: the older shape, board DTB appended to the *gzip stream*
# instead of to the binary. Stops on the realme logo -- the ABL picks that entry
# as the external FDT, it has no /memory, and the internal blob is absent.
cat "$OUT_ABS/payload.gz" "$OUT_ABS/dts/${DTB_SUBDIR:-upstream/src/arm64/qcom}/sdm710-realme-rmx1971.dtb" \
    > "$OUT_ABS/payload-external.gz"
python3 "$ROOT/scripts/pack-boot.py" "$OUT_ABS/payload-external.gz" -o "$OUT_ABS/boot-boarddtb.img"

ls -l "$OUT_ABS/boot.img" "$OUT_ABS/boot-boarddtb.img" "$OUT_ABS/stock-fb.bin" \
      "$OUT_ABS/u-boot+dtb.bin"

# ---------------------------------------------------------------------------
# Extra passes: the same payload with a different default environment. A wrong
# environment costs a flash cycle on a retail handset that cannot be typed at,
# so each experiment is built as its own boot image instead of being an edit
# made after the fact:
#
#   probe - proof of life: no storage, no video dependence, resets itself
#   diag  - read-only storage and partition reconnaissance
#
# The environment is compiled into the binary
# (CONFIG_ENV_DEFAULT_ENV_TEXT_FILE), hence a build directory per variant
# rather than an env change at run time.
build_env_variant() { # $1 = variant name, $2 = env file, $3 = boot image name
	local name=$1 envf=$2 img=$3 dir
	dir="$(dirname "$OUT_ABS")/out-$name"
	echo "== build $name ($dir)"
	make -s O="$dir" qcom_defconfig qcom-phone.config rmx1971.config
	bash ./scripts/config --file "$dir/.config" --set-str ENV_DEFAULT_ENV_TEXT_FILE \
	     "$envf"
	make -s O="$dir" olddefconfig
	build "$dir"
	grep -q "$(basename "$envf")" "$dir/include/generated/autoconf.h" \
	    || { echo "error: $name env did not take effect" >&2; exit 1; }
	make_payload "$dir" "$dir/payload.gz"
	pack "$dir/payload.gz" "$OUT_ABS/$img"
	ls -l "$OUT_ABS/$img"
}

build_env_variant probe board/realme/rmx1971/rmx1971-probe.env boot-probe.img
build_env_variant diag  board/realme/rmx1971/rmx1971-diag.env  boot-diag.img
build_env_variant usb   board/realme/rmx1971/rmx1971-usb.env   boot-usb.img
