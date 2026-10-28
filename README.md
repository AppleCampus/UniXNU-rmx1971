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
| First light (U-Boot banner on the ABL splash) | **not yet confirmed on hardware** — four images have stopped on the splash without resetting; two causes found and fixed since (patched DTB table entries, Image header `text_offset`), see below |
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
gzip -9 -n -c out/u-boot-nodtb.bin > u-boot-nodtb.bin.gz
scripts/patch-stock-dtb.py firmware/stock-appended-dtbs.bin out/stock-fb.bin
scripts/pack-boot.py out/u-boot-nodtb.bin.gz --dtb-table out/stock-fb.bin -o out/boot.img
```

`u-boot.bin` as the kernel field returns `OKAY` to `fastboot boot` and does not
start; a gzip stream is what the ABL expects to decompress, so `u-boot-nodtb.bin`
goes in gzipped, followed by the DTB table.

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

Two attempts on hardware narrowed it down, and neither matched the sibling port:

| Tried | Result |
| --- | --- |
| `gzip(nodtb)` + board DTB + the vendor's six DTBs | stops on the realme logo |
| `gzip(nodtb)` + board DTB alone | drops straight to fastboot, exactly like an empty `boot` partition |
| `gzip(nodtb)` + the vendor's six DTBs, entry 0 patched | stops on the realme logo, and the probe build (`sleep 15; reset`) does **not** reboot either |

The working iOS image on this same handset is packed as `gzip(payload)` followed
by the vendor's six DTBs, untouched. That is the layout ABL is happy with, so
`scripts/patch-stock-dtb.py` stops competing with it and edits the vendor DTBs
in place instead -- everything the vendor put there (PMIC, clocks, GENI UART,
UFS, `oppo,prjversion`, the ABL identity fields) is kept, plus two nodes:

- `framebuffer@9c000000` (`simple-framebuffer`, 1080x2340, stride 4320, `a8r8g8b8`)
  at the splash carve-out the ABL leaves behind, so U-Boot has an output device;
- a `/memory` window -- every vendor entry has `reg = <0 0 0 0>`, because Android
  reads RAM from SMEM, and `qcom_parse_memory()` panics on a zero size.

**All six entries get both nodes**, not just one. The ABL picks an entry by
matching `qcom,msm-id` against the SoC, which is entry 3 on this handset and not
something the image can dictate; patching a single entry leaves U-Boot to panic
`"No valid memory ranges found!"` whenever a different one is selected, and that
panic runs before the console exists -- a handset that sits on the splash and
never resets looks identical whether the CPU never started or died in
`board_init_f`. Patching every entry removes the guess.

`gzip(nodtb)` alone, with no table, is the one shape the ABL rejects outright.

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
`+0x800`, `image_size = 0x2d000`, flags `0xa`. `scripts/build-in-tree.sh` asks
for the same -- it sets `CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE=0x0` on the
generated `.config` after the defconfig, because a kconfig fragment cannot carry
that line (`merge_config` splices the explanatory comment into the assignment and
kconfig then drops it) -- and it refuses to pack an image whose header does not
say `text_offset 0`. `stub/paint-fb.S` reproduces that header byte for byte,
which is what makes `boot-stub.img` a meaningful experiment rather than a second
guess.

| Image | How it is built | Purpose |
| --- | --- | --- |
| `boot.img` | `gzip(nodtb)` + patched vendor DTB table | **flash this one** |
| `boot-probe.img` | same, env is `sleep 15; reset` | proves U-Boot reached `bootcmd` even with no display: the handset reboots by itself ~17 s after the splash |
| `boot-boarddtb.img` | `gzip(nodtb)` + board DTB + vendor table | the first attempt, kept because it reproduces the logo hang |
| `boot-stub.img` | `gzip(paint-fb)` + patched vendor DTB table | no U-Boot at all: ~300 bytes of assembly that flood `0x9c000000` with green, stamp a red square, wait ~10 s, then PSCI-reset. Green means the ABL jumped and the container shape is right; the logo means it never reached our code |

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
