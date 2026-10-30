# ABL boot container and the appended DTB table

Notes for anyone touching the `boot.img` layout. The short version is at the top;
the observations that produced it follow.

## What the ABL accepts

- Kernel field = `gzip(payload)` + a DTB table it can match by `qcom,msm-id`.
  The table is the vendor's own six FDTs (`firmware/stock-appended-dtbs.bin`),
  patched by `scripts/patch-stock-dtb.py`.
- `androidboot.dtb_idx` is ignored. The ABL picks the entry itself, so the image
  cannot choose which FDT is used.
- `fastboot boot` is not available: the ABL has no `boot` command. The image has
  to be flashed to the `boot` partition.
- The payload must carry an arm64 `Image` header with `text_offset = 0`; see
  [the payload's own header](#the-payloads-own-header).

## Why the table is patched rather than replaced

Every vendor entry has `reg = <0 0 0 0>` for `/memory`, because Android reads RAM
from SMEM. `qcom_parse_memory()` in U-Boot looks up the literal path `/memory`
and treats a zero size as `-ENODATA`, so an unpatched table is unusable if that
entry is ever the one selected. The patch adds two nodes to all six entries:

- `/memory` with the low window this board actually has (`0x8000_0000`,
  `0x7e2c_0000` bytes);
- a root-level `framebuffer@9c000000` (`simple-framebuffer`, 1080x2340,
  stride 4320, `a8r8g8b8`).

All six, because the entry is chosen by `qcom,msm-id` and the image cannot
predict it.

## Observations

Four layouts were tried before the fifth worked. Each failure looked the same
from outside: realme logo, no output, no reset.

| Layout | Result |
| --- | --- |
| `gzip(nodtb)` + board DTB + vendor table | stops on the logo |
| `gzip(nodtb)` + board DTB, no table | drops to fastboot, like an empty `boot` partition |
| `gzip(nodtb)` + vendor table, entry 0 patched | logo; the `sleep 15; reset` probe does not fire either |
| the same with all six entries patched and `text_offset` fixed | unchanged |
| `gzip(paint-fb)` + vendor table, no U-Boot at all | screen turns green, red square, PSCI reset |

`stub/paint-fb.S` shares no code with U-Boot: it writes `0x9c000000` and resets
through PSCI. It runs, so the container shape and the splash address were correct
from the start and the fault was inside U-Boot — which is what the payload header and the `/memory` node turned out to be.

## The payload's own header

U-Boot puts a 64-byte Linux `Image` header in front of its payload
(`CONFIG_LINUX_KERNEL_IMAGE_HEADER`, selected by `ARCH_SNAPDRAGON`). The
`text_offset` field is

```c
CONFIG_TEXT_BASE - CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE
```

and those two defaults disagree on a position-independent build:
`qcom_defconfig` sets `CONFIG_POSITION_INDEPENDENT=y`, so `CONFIG_TEXT_BASE` is 0,
while `arch/arm/mach-snapdragon/Kconfig` defaults the base to `0x80000000`. The
field therefore read `-0x80000000`, and a loader computing `base + text_offset`
lands 2 GiB below anything executable.

The working iOS image on this handset is the control: `text_offset = 0`, code at
`+0x800`, `image_size = 0x2d000`, flags `0xa`. kconfig will not produce that value
— neither a fragment nor `scripts/config` overrides the computed field reliably —
so `scripts/build-in-tree.sh` rewrites the two fields after the build and fails
unless the header then reads `text_offset 0` with `image_size` equal to the
payload length. `stub/paint-fb.S` carries the same header by hand.

## The two device tree copies

`fdtdec_setup()` asks `fdt_find_separate()` for the blob, which on
`CONFIG_OF_SEPARATE` is `_end` — the byte immediately after `u-boot-nodtb.bin`.
`board_fdt_blob_setup()` then compares that internal blob with the one the ABL
left in `x0` and panics if neither is a valid FDT:

```c
if (!internal_valid && !external_valid)
	panic("Internal FDT is invalid and no external FDT was provided!");
```

With `CONFIG_PANIC_HANG=y` (from `qcom-phone.config`) that panic is a silent wait
before the console exists, which is why the handset simply sits on the splash.

Consequences for the build:

- the payload is `u-boot-nodtb.bin` followed by the board DTB at exactly its
  length, with no padding, so `_end` is a valid FDT;
- the board DTS defines `/memory` itself (see above), because `sdm670.dtsi` ships
  `memory@80000000` with a zero-size placeholder that `qcom_parse_memory()` cannot
  see;
- the framebuffer node sits at the root of the tree, not under `/chosen`. Driver
  model walks the root's children and recurses only into simple-bus nodes;
  `/chosen` has no driver, so a framebuffer nested there is never bound and
  `vidconsole` never appears.
