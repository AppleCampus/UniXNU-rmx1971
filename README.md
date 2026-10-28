# rmx1971-unixnu

U-Boot for the **Realme 5 Pro** (`RMX1971`, Qualcomm SM712 / SDM712), built as an
Android boot image so it can be written to the `boot` partition.

This is step 1 of a possible [UniXNU](https://github.com/FFT-infra/UniXNU) port:
UniXNU boots through a UEFI environment, and on this SoC family the cheapest way
to get one is U-Boot's EFI loader rather than a Mu-Silicium (EDK2) platform.
[Xiaomi Mi 8 SE](https://github.com/57UU/UniXNU-sirius) (sirius, SDM710) proved
that path on the same silicon: `boot.img = U-Boot`, FAT payload volume on a spare
partition, `UniXNU.efi` started from `\EFI\BOOT\BOOTAA64.EFI`, then `DarwinBoot`
and XNU.

Nothing here is installed by the build. On this handset the image has to be
**flashed** to `boot` (`/dev/block/sde10`), because OPPO/realme's ABL ships
without the `boot` command -- `fastboot boot` transfers the image and then fails
with `FAILED (remote: 'unknown command')`. Recovery is the same one command:
flash the previous `boot.img` back.

## State

| Piece | State |
| --- | --- |
| U-Boot defconfig, env, DTS for RMX1971 | written, builds in CI |
| ABL accepting the image and jumping into it | **confirmed on hardware** — `boot-stub.img` paints the screen green with a red square and resets |
| First light (U-Boot banner on the ABL splash) | **not yet confirmed on hardware** — U-Boot itself dies before `bootcmd`; the devicetree it was given is the current suspect, see below |
| Storage (UFS at `0x1d84000`) | node enabled, untested |
| Input, USB, panel init | not attempted — the ABL already leaves a lit panel |

The console is the framebuffer the ABL hands over at `0x9c000000` (1080x2340,
stride 1080x4, a8r8g8b8). Retail units have no UART, so this is the only output
we get; `stdout=vidconsole`.

## Build

GitHub Actions builds it on every push (`.github/workflows/uboot.yml`, artifact
`rmx1971-uboot`). Locally, on a Linux host with `gcc-aarch64-linux-gnu`:

```sh
git clone --depth 1 -b sirius/v2.0 https://github.com/57UU/u-boot uboot
scripts/overlay.sh uboot
scripts/build-in-tree.sh uboot out      # -> out/boot.img
```

The recipe follows sirius's, which is the only known-good one for this SoC:

```sh
make O=out qcom_defconfig qcom-phone.config board/realme/rmx1971/rmx1971.config
make O=out DEVICE_TREE=qcom/sdm710-realme-rmx1971
cat out/u-boot-nodtb.bin out/dts/upstream/src/arm64/qcom/sdm710-realme-rmx1971.dtb > u-boot+dtb.bin
gzip -9 -n -c u-boot+dtb.bin > payload.gz
scripts/patch-stock-dtb.py firmware/stock-appended-dtbs.bin out/stock-fb.bin
scripts/pack-boot.py payload.gz --dtb-table out/stock-fb.bin -o out/boot.img
```

`u-boot.bin` as the kernel field returns `OKAY` to `fastboot boot` and does not
start; a gzip stream is what the ABL expects to decompress. Two things ride
behind it: the board DTB, appended to the binary so U-Boot finds its own tree at
`_end` (see below), and the vendor DTB table, appended to the compressed stream
because the ABL wants a table it can match by `qcom,msm-id`.

## Test

```sh
fastboot devices
fastboot flash boot out/boot.img
fastboot reboot
```

Expect the U-Boot banner over the ABL splash, then `scsi scan`, then a failed
`bootefi bootmgr` and the prompt. A black or unchanged screen means it did not
get that far; the `boot` partition is the only thing touched, so flashing the
previous image back restores everything.

### What the ABL actually wants

Four attempts on hardware narrowed it down, and none of them matched the sibling
port:

| Tried | Result |
| --- | --- |
| `gzip(nodtb)` + board DTB + the vendor's six DTBs | stops on the realme logo |
| `gzip(nodtb)` + board DTB alone | drops straight to fastboot, exactly like an empty `boot` partition |
| `gzip(nodtb)` + the vendor's six DTBs, entry 0 patched | stops on the realme logo, and the probe build (`sleep 15; reset`) does **not** reboot either |
| the same with all six entries patched, `text_offset` fixed to 0 | unchanged: logo, no output, no reset |
| `gzip(paint-fb)` + the vendor table — no U-Boot, 300 bytes of assembly | **screen turns green, red square top-left, handset resets** |

That last row is the one worth keeping. `stub/paint-fb.S` shares nothing with
U-Boot -- it writes `0x9c000000` directly and resets through PSCI -- and it runs.
So the ABL accepts this container, jumps into it, and the splash address the two
payloads use is correct. Everything the images above got wrong is inside U-Boot,
and the useful question stops being "what does the ABL want" and becomes "why
does U-Boot die before `bootcmd`".

The working iOS image on this same handset is packed as `gzip(payload)` followed
by the vendor's six DTBs, untouched, which is why the table stays. What changes is
who that table is for: it is there for the ABL to match against, not for U-Boot
to read. `scripts/patch-stock-dtb.py` still adds a framebuffer node and a
`/memory` window to every entry, so a bootloader that *does* use one of them gets
something usable:

- `framebuffer@9c000000` (`simple-framebuffer`, 1080x2340, stride 4320, `a8r8g8b8`)
  at the splash carve-out the ABL leaves behind;
- a `/memory` window -- every vendor entry has `reg = <0 0 0 0>`, because Android
  reads RAM from SMEM, and `qcom_parse_memory()` panics on a zero size.

**All six entries get both nodes**, not just one: the ABL picks by `qcom,msm-id`
and the image cannot dictate the choice. `gzip(nodtb)` alone, with no table, is
the one shape the ABL rejects outright.

### The arm64 Image header

The second thing that had to match: the 64-byte Linux `Image` header U-Boot puts
in front of its payload (`CONFIG_LINUX_KERNEL_IMAGE_HEADER`, pulled in by
`ARCH_SNAPDRAGON`). Its `text_offset` field is computed as

```c
TEXT_OFFSET = CONFIG_TEXT_BASE - CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE
```

and those two defaults disagree on a position-independent build:
`qcom_defconfig` sets `CONFIG_POSITION_INDEPENDENT=y` so `CONFIG_TEXT_BASE` is 0,
while `arch/arm/mach-snapdragon/Kconfig` defaults the base to `0x80000000`. The
field therefore read `-0x80000000`, and a bootloader that computes
`base + text_offset` lands 2 GiB below the base load address -- nothing to
execute, no reset, no output: the handset sits on the splash.

The working iOS shim on this device is the control: `text_offset = 0`, code at
`+0x800`, `image_size = 0x2d000`, flags `0xa`. kconfig cannot be talked into
that value -- `TEXT_OFFSET` is `CONFIG_TEXT_BASE - CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE`
and the two defaults disagree on a position-independent snapdragon build (0
versus `0x80000000`), while neither a kconfig fragment nor `scripts/config`
reliably overrides it -- so `scripts/build-in-tree.sh` rewrites the two fields in
the produced payload (pure data, nothing in U-Boot reads them back) and fails the
build unless the header then says `text_offset 0` with `image_size` equal to the
payload size. `stub/paint-fb.S` carries that header by hand for the same reason,
which is what makes `boot-stub.img` a meaningful experiment rather than a second
guess.

### The devicetree U-Boot boots with

`fdtdec_setup()` asks `fdt_find_separate()` for the blob, which on a
`CONFIG_OF_SEPARATE` build is `_end` -- the byte right after `u-boot-nodtb.bin`.
Only then does the board get a say: `board_fdt_blob_setup()` in
`arch/arm/mach-snapdragon/board.c` compares that internal blob with the one the
ABL left in `x0`, and if neither is a valid FDT it panics:

```c
if (!internal_valid && !external_valid)
	panic("Internal FDT is invalid and no external FDT was provided!");
```

The payload used to be `gzip(u-boot-nodtb.bin)`, so `_end` pointed at whatever
followed the image in RAM: there was no internal blob at all, and the only route
left was to trust the ABL. Nothing had ever shown that the ABL hands this image a
valid FDT -- it hands *something* over, but the image cannot tell what. And
`CONFIG_PANIC_HANG=y` (from `qcom-phone.config`) turns that panic into a wait
forever, before the console exists, which is why the handset sits on the splash
without a single character of output.

Two halves to the fix:

- the payload is `u-boot-nodtb.bin` followed by the board DTB at exactly its own
  length, so `_end` *is* a valid FDT and U-Boot stops needing the ABL's copy. Any
  padding would move the blob away from `_end`, hence no alignment at all.
- the board DTS defines the `/memory` node U-Boot looks for. `sdm670.dtsi` ships
  `memory@80000000` with `reg = <0 0x80000000 0 0>` and the comment "we expect the
  bootloader to fill in the size", but `qcom_parse_memory()` reads
  `fdt_path_offset(fdt, "/memory")` -- literal name, no unit address -- so that
  placeholder is invisible to it, and its zero size would fail the next check
  anyway. `dts/sdm710-realme-rmx1971.dts` deletes it and adds
  `memory { reg = <0 0x80000000 0 0x7e2c0000>; }`.

`scripts/build-in-tree.sh` refuses to pack unless all of that holds: the FDT magic
must be at `len(u-boot-nodtb.bin)` inside the payload, `/memory` must be 16 bytes
(two 64-bit cells, the way `qcom_parse_memory()` reads it) with a non-zero size,
and -- as a second opinion that shares no code with ours -- the `dtc` the U-Boot
build just produced has to parse the extracted blob and find the node.

The framebuffer node also moved out of `/chosen`, where the sirius DTS keeps it,
to the root of the tree. `dm_scan_fdt()` walks the root's children and recurses
only into nodes bound as simple-bus (`dm_scan_fdt_node()` ->
`simple_bus_post_bind()`), and `/chosen` has no driver -- a framebuffer nested
under it is never bound, `vidconsole` never appears, and on a handset without a
UART that is a board that runs but cannot say anything.

| Image | How it is built | Purpose |
| --- | --- | --- |
| `boot.img` | `gzip(nodtb + board DTB)` + patched vendor DTB table | **flash this one** |
| `boot-probe.img` | same, env is `sleep 15; reset` | proves U-Boot reached `bootcmd` even with no display: the handset reboots by itself ~17 s after the splash |
| `boot-boarddtb.img` | board DTB *after* the gzip stream, not inside it | reproduces the logo hang: the ABL then picks that entry as the external FDT and it has no `/memory` |
| `boot-stub.img` | `gzip(paint-fb)` + patched vendor DTB table | no U-Boot at all: ~300 bytes of assembly that flood `0x9c000000` with green, stamp a red square, wait ~10 s, then PSCI-reset. Green means the ABL jumped and the container shape is right; done, that one passed |

The probe environment is compiled in (`CONFIG_ENV_DEFAULT_ENV_TEXT_FILE`), which
is why it needs a second build directory rather than an env change at run time.

## Board facts used here

Taken from this handset, not from the reference board:

| Item | Value | Source |
| --- | --- | --- |
| ABL identity | `qcom,msm-id = <0x168 0 0x189 0>`, `board-id = <0 0>` | every entry of `firmware/stock-appended-dtbs.bin` |
| Framebuffer | `0x9c000000`, 1080x2340, stride `1080*4`, `a8r8g8b8` | ABL `cont_splash`, the same numbers the iOS port uses |
| Storage | UFS host `0x1d84000` (no eMMC) | `/dev/block/sde*` on the device |
| GIC / timer | GICD `0x17a00000`, GICR `0x17a60000`, 19.2 MHz, vtimer INTID 19 | `UniXNU-sdm710-common` and the iOS port's ADT |
| Boot image | page 4096, kernel `0x8000`, ramdisk `0x1000000`, tags `0x100`, header v1 | stock `boot.img` |

`firmware/stock-appended-dtbs.bin` is the vendor's appended-DTB area, six FDTs
concatenated with no padding, straight out of the stock `boot.img`. It ships
with the image because the ABL needs a table it can match by `qcom,msm-id`;
`androidboot.dtb_idx` is *not* passed (the ABL decides, the image cannot). It
contains no serial numbers or calibration data.

## Differences from sirius

- Panel is 1080x2340 (sirius: 1080x2240), still drawn by simple-framebuffer.
- UFS instead of eMMC: `&ufs_mem_hc` / `&ufs_mem_phy` are enabled, `&sdhc_1` is off.
- Volume keys are left on PM660L GPIO 7 until this board's stock DTB is checked.

## Next

1. First light on hardware, then `scsi scan` reaching `ufs 0`.
2. A FAT payload partition and `UniXNU.efi` from a UniXNU checkout.
3. Board wiring for the UniXNU device repository: DTS for the kernel side, then
   the `UniXNU-sdm710-common` SoC profile.

## License

GPL-2.0-or-later for the U-Boot pieces (the DTS derives from GPL-2.0 sources and
the board files are U-Boot configuration). See `LICENSE`.
