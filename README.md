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
| First light (U-Boot banner on the ABL splash) | **not yet confirmed on hardware** |
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
gzip -c out/u-boot-nodtb.bin > u-boot-nodtb.bin.gz
cat u-boot-nodtb.bin.gz sdm710-realme-rmx1971.dtb > uboot-payload
```

`u-boot.bin` as the kernel field returns `OKAY` to `fastboot boot` and does not
start; the gzip stream plus the appended DTB is what works.

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

The working iOS image on this same handset is packed as `gzip(payload)` followed
by the vendor's six DTBs, untouched. That is the layout ABL is happy with, so
`scripts/patch-stock-dtb.py` stops competing with it and edits the vendor DTB
in place instead -- everything the vendor put there (PMIC, clocks, GENI UART,
UFS, `oppo,prjversion`, the ABL identity fields) is kept, plus two nodes:

- `framebuffer@9c000000` (`simple-framebuffer`, 1080x2340, stride 4320, `a8r8g8b8`)
  at the splash carve-out the ABL leaves behind, so U-Boot has an output device;
- a `/memory` window -- the vendor node has `reg = <0 0 0 0>`, because Android
  reads RAM from SMEM, and `fdtdec_setup_mem_size_base()` hangs on a zero size.

| Image | How it is built | Purpose |
| --- | --- | --- |
| `boot.img` | `gzip(nodtb)` + patched vendor DTB table | **flash this one** |
| `boot-probe.img` | same, env is `sleep 15; reset` | proves the CPU executes U-Boot even with no display: the handset reboots by itself ~17 s after the splash |
| `boot-boarddtb.img` | `gzip(nodtb)` + board DTB + vendor table | the first attempt, kept because it reproduces the logo hang |

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
| Boot image | page 4096, kernel `0x8000`, ramdisk `0x1000000`, tags `0x100`, header v1, `dtb_idx=3` | stock `boot.img` |

`firmware/stock-appended-dtbs.bin` ships with the image because ABL reads
`dtb_idx=3` from it; it contains no serial numbers or calibration data.

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
