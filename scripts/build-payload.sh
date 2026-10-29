#!/usr/bin/env bash
# Build an aarch64 UEFI application into a PE32+ image.
#
#   scripts/build-payload.sh [out dir]
#
# clang emits COFF for --target=aarch64-pc-win32-coff and lld-link turns that
# into the PE32+ that EFI_LOADER expects, which is why neither gnu-efi nor a
# mingw cross toolchain is needed. The MS ABI that comes with that target is the
# one the firmware calls with, so a plain C function can be the entry point.
#
# /subsystem:efi_application and /entry:efi_main are what make the result an EFI
# application rather than a console program; /nodefaultlib keeps libcmt out,
# since freestanding code has no CRT to initialise.
set -euo pipefail

OUT=${1:-out-payload}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CC=${CC:-clang}
LINK=${LINK:-lld-link}

mkdir -p "$OUT"

"$CC" --target=aarch64-pc-win32-coff \
	-ffreestanding -nostdlib -fno-stack-protector -fshort-wchar \
	-O2 -Wall -Wextra \
	-c "$ROOT/payload/hello.c" -o "$OUT/hello.o"

"$LINK" /subsystem:efi_application /entry:efi_main /nodefaultlib \
	/out:"$OUT/hello.efi" "$OUT/hello.o"

# A PE32+ file starts with "MZ", carries "PE\0\0" at e_lfanew and names
# machine 0xAA64 (aarch64) in its COFF header. Checking all three catches the
# case where the toolchain silently produced an x86 binary, which would flash
# and load fine and then fail in a far less obvious way.
python3 - "$OUT/hello.efi" <<'PY'
import struct, sys

blob = open(sys.argv[1], "rb").read()
if blob[:2] != b"MZ":
    sys.exit("error: no MZ header")
pe = struct.unpack_from("<I", blob, 0x3C)[0]
if blob[pe:pe + 4] != b"PE\0\0":
    sys.exit("error: no PE signature")
machine, nsect = struct.unpack_from("<HH", blob, pe + 4)
opt_magic = struct.unpack_from("<H", blob, pe + 24)[0]
if machine != 0xAA64:
    sys.exit(f"error: machine {machine:#x}, expected 0xAA64")
if opt_magic != 0x20B:
    sys.exit(f"error: optional header magic {opt_magic:#x}, expected PE32+ 0x20b")
print(f"    hello.efi: {len(blob)} bytes, PE32+ aarch64, {nsect} sections")
PY

ls -l "$OUT/hello.efi"
