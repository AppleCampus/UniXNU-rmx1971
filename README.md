# UniXNU for the Realme 5 Pro (rmx1971)

[![U-Boot](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/uboot.yml/badge.svg)](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/uboot.yml)
[![kernel](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/unixnu-kernel.yml/badge.svg)](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/unixnu-kernel.yml)
[![payload](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/unixnu-efi.yml/badge.svg)](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/unixnu-efi.yml)

[UniXNU](https://github.com/UniXNU/UniXNU) device support for the **Realme 5 Pro**
(RMX1971, Snapdragon 712 / SDM712): source XNU kernel and an iPadOS userland,
booted through a UEFI environment this repository also builds.

Format 2 port (`schema_version = 2`): shared ARM64, SoC and OS profiles, board
wiring only. Shared SoC layer: [UniXNU-sdm710-common](https://github.com/57UU/UniXNU-sdm710-common).

```
ABL → boot.img (U-Boot) → FAT32 ESP on vm-system
      \EFI\BOOT\BOOTAA64.EFI          UniXNU.efi
      \EFI\UniXNU\unixnu.toml         menu + kernel arguments
      \EFI\UniXNU\Payloads\           DarwinBoot.efi, kernel.macho (+ .adt)
                                      → XNU (iPadOS 17.7.11, 21H461)
```

## Status

| Component | State | Notes |
| --- | --- | --- |
| ABL handover | Working | stock ABL, `boot.img` = `gzip(payload)` + vendor DTB table |
| Display / framebuffer | Working | 1080x2340 `a8r8g8b8` at `0x9c000000`, simple-framebuffer |
| UFS host | Working | HS-GEAR3, 6 LUNs, 4096-byte blocks |
| UEFI (boot manager, block I/O, console) | Working | U-Boot `EFI_LOADER` |
| `UniXNU.efi` | Working | menu drawn on the panel, reads `unixnu.toml` |
| XNU entry | Working | 8 CPUs, 19.2 MHz counter, kernel console on the panel |
| Root device | In progress | `vfs_mountroot` retries; UFS driver builds, first hardware run pending |
| USB gadget | Blocked | `fastboot usb 0` never enumerates; all flashing goes through the ABL |
| Serial console | Not present | no UART on retail units; the framebuffer is the log |

## Flash

```sh
fastboot flash vm-system rmx1971-payload.img     # ESP: UniXNU + DarwinBoot + kernel
fastboot flash boot     uboot-rmx1971-boot.img   # U-Boot
fastboot reboot
```

`vm-system` is a 128 MiB OPPO virtualisation partition this project does not use.
`boot.img` must be flashed, not booted: the ABL has no `boot` command, so
`fastboot boot` transfers the image and fails with `FAILED (remote: 'unknown
command')`. Flashing any earlier `boot.img` — including the stock one — restores
the device.

After the first pair is on, only the payload changes: `fastboot flash vm-system …`
and reboot, no firmware rebuild.

## Build

| Workflow | Runner | Output |
| --- | --- | --- |
| `uboot.yml` | ubuntu | `boot.img`, `boot-probe.img`, `boot-diag.img`, `boot-usb.img`, `boot-stub.img` |
| `unixnu-kernel.yml` | macOS (Xcode, `unixnu build kernel` runs nowhere else) | `kernel.macho` + `.adt` |
| `unixnu-efi.yml` | ubuntu | `rmx1971-payload.img` from the newest successful kernel run |

Local U-Boot build (`gcc-aarch64-linux-gnu`, `bison`, `flex`, `dtc`):

```sh
git clone --depth 1 -b sirius/v2.0 https://github.com/57UU/u-boot uboot
scripts/overlay.sh uboot
scripts/build-in-tree.sh uboot out          # -> out/boot.img, out/boot-probe.img, ...
```

`build-in-tree.sh` fails the build rather than shipping a broken image: kconfig
silently drops symbols whose dependencies are unmet (so `require_config` re-reads
the resulting `.config`), the FDT must sit at `len(u-boot-nodtb.bin)`, and the
`dtc` from the build must parse the extracted blob and find `/memory`.

## Bring-up checks

Three probes, in increasing order of how much they prove. All three are boot
images for the same partition, so they are interchangeable.

**1. Does the ABL jump at all?** 300 bytes of assembly, no U-Boot, no kernel.
Needs only a cross toolchain:

```sh
scripts/build-stub.sh out-stub
fastboot flash boot out-stub/boot-stub.img
```

Expected: screen turns green, red square in the top-left, PSCI reset after ~10 s.
That confirms the container layout and the splash address at `0x9c000000`.

**2. Did U-Boot reach `bootcmd`?** Same image with an environment of
`sleep 15; reset` (`out/boot-probe.img`). Reboots by itself ~17 s after the splash
if the payload started; sits still if it did not.

**3. Can it read the disk?** `out/boot-diag.img` runs `part list` and a few
`scsi read`s, printing LBA, size and the first bytes of `boot`. Read-only.

The same three ideas are why the main environment is a single `bootcmd` line:

```
bootefi bootmgr
  → on failure: scsi read 0xa0000000 0x19391 400 ; bootefi 0xa0000000:400000
```

The fallback starts a PE image written to `logfs` (8 MiB, unused). The `:size`
suffix is required — `bootefi <addr>` alone only accepts addresses the EFI loader
recorded itself and answers `No UEFI binary known at ...`.

## Partition map

Six LUNs, 63.99 GB in total, 4096-byte blocks:

| LUN | Size | Contents |
| --- | --- | --- |
| 0 | 58.6 GiB | Android: `ssd persist misc keystore frp vm-keystore vm-data` **`vm-system`** `vm-linux cache system vendor odm userdata` |
| 1 | 4 MiB | `xbl`, `xbl_config` |
| 2 | 4 MiB | valid but empty GPT |
| 3 | 32 MiB | `ALIGN_TO_128K_1`, `cdt`, `ddr` |
| 4 | 656 MiB | `aop tz hyp hypbak modem bluetooth abl dsp keymaster` **`boot`** `cmnlib cmnlib64 devcfg qupfw vbmeta recovery dtbo …` `logfs` `rawdump` `logdump` |
| 5 | 256 MiB | `ALIGN_TO_128K_2 oppodycnvbk oppostanvbk modemst1 modemst2 opporeserve1..3 carrier DRIVER fsg fsc` |

LBAs that matter, read from the device with `part list`, in 4 KiB units:

| Partition | LUN | first LBA | blocks |
| --- | --- | --- | --- |
| `boot` | 4 | `0xc505` | `0x4000` (64 MiB) |
| `recovery` | 4 | `0x1064e` | `0x4000` |
| `dtbo` | 4 | `0x1464e` | `0x1000` |
| `logfs` | 4 | `0x19391` | `0x800` (8 MiB) |
| `vm-system` | 0 | `0x2d00` | `0x8000` (128 MiB) |
| `userdata` | 0 | `0x198900` | `0xd11ef3` (52.3 GiB) |

## Notes

- **Board numbers**: panel 1080x2340 at `0x9c000000`; UFS at `0x1d84000`;
  GICD `0x17a00000`, GICR `0x17a60000`; 19.2 MHz counter, vtimer INTID 19; big
  cores 2.3 GHz, GPU 610 MHz. Volume keys are assumed on PM660L GPIO 7.
- **Boot container**: `gzip` stream, not a raw `Image`, plus a DTB table the ABL
  matches by `qcom,msm-id`. Every entry has to be patched — the image cannot pick
  one, because `androidboot.dtb_idx` is ignored. See
  [docs/bringup/abl-dtb.md](docs/bringup/abl-dtb.md).
- **Heap for the kernel**: `owned_memory_size = 0x20000000`. More than ~1 GiB is
  refused with `out of resources`, because the EFI map only covers the low half.
  See [docs/bringup/xnu-boot.md](docs/bringup/xnu-boot.md).
- **Storage**: UFS clock gate `137` is missing from the sdm670 table in U-Boot;
  the XNU root driver is read-only and probed from `vfs_mountroot()`. See
  [docs/bringup/ufs-root.md](docs/bringup/ufs-root.md).
- **No UART**: every experiment is compiled into the image, and the kernel's
  diagnostics go to the framebuffer (`boot-progress=2`). The panel shows CPU,
  memory, clock, SMP state and the current kernel stage; `stage:` plus the PC
  samples is how a hang is located.
- **Machine-readable record**: [`porting.toml`](porting.toml), validated with
  `scripts/porting-record.py check --device .` from a UniXNU checkout. Raw device
  observations live in [docs/bring-up.md](docs/bring-up.md).

## Layout

| Path | What it is |
| --- | --- |
| `board/realme/rmx1971/` | U-Boot kconfig fragment and four environments |
| `dts/sdm710-realme-rmx1971.dts` | U-Boot tree: `/memory`, root-level framebuffer |
| `dts/rmx1971.dts` | XNU tree: memory window, eight `/cpus` |
| `board.toml`, `configs/`, `feeds.toml` | UniXNU device descriptor and kernel configuration |
| `package/` | kernel kits: boot-progress panel, fault probe, PMGR nub, inert stubs |
| `drivers/ArmCpu`, `drivers/DarwinBoot` | CPU/GIC/timer driver, XNU loader |
| `patches/uboot/`, `patches/xnu/` | UFS clock gate; read-only UFS root driver |
| `scripts/` | overlay, build, pack, header fix-up, patch generator |
| `stub/paint-fb.S` | the ABL proof of life |
| `firmware/stock-appended-dtbs.bin` | the vendor's six FDTs |

## Next

1. Read the UFS driver's `stage:` line on hardware: `UFS ok: …` moves the problem
   to the filesystem, `UFS: init failed <errno>` names the stage.
2. Put a mountable root on a partition — a small HFS image first, then a full one.
3. Userland.

## License

GPL-2.0-or-later; see `LICENSE`. The board DTS derives from GPL-2.0 sources.
