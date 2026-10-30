# UniXNU for the Realme 5 Pro (rmx1971)

[![U-Boot](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/uboot.yml/badge.svg)](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/uboot.yml)
[![kernel](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/unixnu-kernel.yml/badge.svg)](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/unixnu-kernel.yml)
[![payload](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/unixnu-efi.yml/badge.svg)](https://github.com/AppleCampus/UniXNU-rmx1971/actions/workflows/unixnu-efi.yml)

[UniXNU](https://github.com/UniXNU/UniXNU) device support for the **Realme 5 Pro**
(RMX1971, Qualcomm Snapdragon 712 / SDM712): bringing the source XNU kernel and
an iPadOS userland up on this phone, through a UEFI environment that this
repository also builds.

Format 2 port (`schema_version = 2`): the board selects shared ARM64, SoC and OS
profiles and supplies only its own wiring. The shared SDM710 layer is
[UniXNU-sdm710-common](https://github.com/57UU/UniXNU-sdm710-common); SDM712 is
the same die with a 100 MHz higher big-core clock.

| Repository | Contents |
| --- | --- |
| [UniXNU](https://github.com/UniXNU/UniXNU) | build driver, kernel patch series, kits, documentation |
| [UniXNU-sdm710-common](https://github.com/57UU/UniXNU-sdm710-common) | shared SDM710/712 SoC layer: GIC-500, 19.2 MHz counter, PSCI |
| **UniXNU-rmx1971** (this) | board description, device tree, U-Boot firmware, UFS root driver, payload assembly |

Three layers, all of them working on hardware:

```
ABL  ->  boot.img  =  U-Boot 2026.07
             |
             `->  FAT32 ESP on LUN0 partition 8 (vm-system, 128 MiB)
                     \EFI\BOOT\BOOTAA64.EFI            UniXNU.efi
                     \EFI\UniXNU\unixnu.toml           menu + kernel arguments
                     \EFI\UniXNU\Payloads\DarwinBoot.efi
                     \EFI\UniXNU\Payloads\kernel.macho + kernel.macho.adt
                             |
                             `->  XNU  (xnu-10063.141.1, iPadOS 17.7.11 21H461)
```

U-Boot provides the UEFI environment. Porting a full EDK2 platform for this SoC
would be a second firmware project; booting the board's own U-Boot instead gives
the EFI boot manager, block I/O over the UFS partitions and a framebuffer console,
while the board's own clock and storage code stays in charge of the hardware.

## Status

| Stage | State |
| --- | --- |
| U-Boot on the ABL splash | **working** — banner, `Model: Realme 5 Pro (RMX1971)`, `=>` prompt |
| UFS (`ufshc@1d84000`) | **working** — HS-GEAR3, six LUNs enumerated, `part list` reads the GPT |
| Partition map | **known** — [where everything lives](#where-everything-lives); `boot` is LUN4 LBA `0xc505` |
| EFI boot manager finding the ESP | **working** — U-Boot binds the FAT volume and starts `\EFI\BOOT\BOOTAA64.EFI` |
| `UniXNU.efi` | **working** — its menu draws on the framebuffer and it reads `unixnu.toml` |
| `DarwinBoot.efi` handing over to XNU | **working** — stage bars drawn, kernel entry reached |
| XNU itself | **working** — 8 CPUs online, 19.2 MHz counter, console on the panel |
| Root device | **in progress** — the kernel reaches `vfs_mountroot` and retries; the read-only UFS driver for it is in `patches/xnu/` and builds, first hardware run pending |
| USB gadget (U-Boot's own fastboot) | blocked — `fastboot usb 0` waits for a host that never enumerates; everything goes through the ABL instead |
| Panel init beyond the ABL splash | not needed — the ABL leaves a lit framebuffer at `0x9c000000` |
| Touch / keys at the U-Boot prompt | unavailable — `stdin=serial,button-kbd`, no UART on retail units. Every experiment is compiled into the environment |

Retail units have no UART. The framebuffer is the only output anyone gets, which
is why the diagnostic panel described under [The panel](#the-panel) exists at all.

## Flash it

Two images, two partitions. `vm-system` is a 128 MiB OPPO virtualisation
partition this project does not use, which makes it the safe landing pad for the
payload; `boot` is the partition the ABL starts.

```sh
fastboot flash vm-system rmx1971-payload.img    # the ESP: UniXNU + DarwinBoot + kernel
fastboot flash boot     uboot-rmx1971-boot.img  # U-Boot itself
fastboot reboot
```

Both come out of CI (see [Build](#build)). Once the first pair is on, only the
payload changes during development: `fastboot flash vm-system …` and a reboot,
no firmware rebuild.

`boot.img` has to be **flashed**: OPPO/realme's ABL ships without the `boot`
command, so `fastboot boot` transfers the image and then fails with
`FAILED (remote: 'unknown command')`. Recovery is one command — flash the stock
`boot.img` back, or any earlier one from this repository.

## Layout

| Path | What it is |
| --- | --- |
| `board/realme/rmx1971/` | U-Boot board files: `rmx1971.config` (kconfig fragment) and four environments (main, probe, diag, usb) |
| `dts/sdm710-realme-rmx1971.dts` | U-Boot's device tree: `/memory`, root-level `framebuffer@9c000000` |
| `dts/rmx1971.dts` | XNU's device tree: memory window and eight `/cpus` nodes over `sdm710.dtsi` |
| `board.toml` | the UniXNU device repository descriptor (format 2) |
| `configs/rmx1971_defconfig` | kernel configuration: the shared sdm710 first-console set, unchanged |
| `feeds.toml` | pins `UniXNU-sdm710-common` |
| `package/` | kernel-side kits: boot-progress display, fault probe, PMGR nub, inert stubs |
| `drivers/ArmCpu`, `drivers/DarwinBoot` | the CPU/GIC/timer driver and XNU's loader |
| `patches/uboot/` | one patch: the missing UFS clock gate |
| `patches/xnu/` | `sweet-ufs-root.patch`: a read-only block driver for the internal UFS |
| `payload/` | `hello.efi` smoke test and a minimal `unixnu.toml` |
| `scripts/` | overlay, build, pack, header fix-up, patch generator, `check-pe.py` |
| `stub/paint-fb.S` | 300 bytes of assembly that paints the screen and resets — the ABL proof of life |
| `firmware/stock-appended-dtbs.bin` | the vendor's six appended FDTs, needed because the ABL matches on `qcom,msm-id` |

## Build

Three workflows, each with a narrow input filter:

| Workflow | Runner | Produces |
| --- | --- | --- |
| `uboot.yml` | ubuntu | `boot.img`, `boot-probe.img`, `boot-diag.img`, `boot-usb.img`, `boot-stub.img` |
| `unixnu-kernel.yml` | **macOS** — `unixnu build kernel` needs Xcode and cannot run elsewhere | `kernel.macho` + `.adt` |
| `unixnu-efi.yml` | ubuntu | `rmx1971-payload.img`, the 128 MiB FAT32 ESP, assembled from the newest successful kernel run |

Locally, on Linux with `gcc-aarch64-linux-gnu`:

```sh
git clone --depth 1 -b sirius/v2.0 https://github.com/57UU/u-boot uboot
scripts/overlay.sh uboot
scripts/build-in-tree.sh uboot out      # -> out/boot.img
```

The U-Boot recipe this SoC needs:

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
`_end`, and the vendor DTB table, appended to the compressed stream because the
ABL wants a table it can match by `qcom,msm-id`.

Three assertions in `build-in-tree.sh` exist because kconfig fails quietly.
`require_config` checks that the symbols the board needs actually survived the
merge — kconfig drops a symbol whose dependencies are unmet without a word, which
is how a `boot.img` once shipped without `part` and `fatls`. The FDT magic must
sit at `len(u-boot-nodtb.bin)`, and the `dtc` the build just produced has to parse
the extracted blob and find `/memory`.

## The panel

XNU's console on this board is `package/BootProgress.c`: a diagnostic view drawn
straight onto the framebuffer by a kit linked into the kernel. It exists because
there is no UART — without it a kernel that hangs is indistinguishable from a
kernel that never started. It refreshes a fixed set of lines:

```
TOPO boot=0 max=7 nums=01234567 | DT cfg=1 cpu=8 dev=1 bus=1 nv=1
MEM totalMiB=512 free4K=... wired=...
CLK cntfrq=19200000 dt-timebase=19200000 dt-converted=...ms
SMP req=1 run=7 cond=1 boot=0 | c1=step7 ... c7=step7
UFS TIME verify=0 ms read=0 ms ...          <- upstream's native-UFS statistics
stage: pid=0 kernel_task bsd_init: vfs_mountroot?
```

`stage:` and the eight PC samples below it are the useful part: they say which
phase the kernel is in and what it is doing right now. That is how the current
stopping point was identified — every sample landed on `_machine_idle`, so the
kernel was not crashed, it was waiting for a root device that did not exist, and
`bsd_init` was re-entering `vfs_mountroot` every five seconds.

The console pane keeps the **latest** seven lines, which is what makes a verbose
boot readable: whatever scrolled last is the answer.

## Where everything lives

`ufshcd` enumerates six LUNs totalling 63.99 GB — a 64 GB handset, all of it:

| LUN | Size | Contents |
| --- | --- | --- |
| 0 | 58.6 GiB | Android: 14 partitions in one GPT |
| 1 | 4 MiB | `xbl`, `xbl_config` |
| 2 | 4 MiB | a valid but empty GPT |
| 3 | 32 MiB | `ALIGN_TO_128K_1`, `cdt`, `ddr` |
| 4 | 656 MiB | firmware: `aop tz hyp hypbak modem bluetooth abl dsp keymaster` **`boot`** `cmnlib cmnlib64 devcfg qupfw vbmeta recovery dtbo storsec oppo_sec sec devinfo dip apdp msadp spunvm dpo splash limits toolsfv logfs sti rawdump logdump` |
| 5 | 256 MiB | `ALIGN_TO_128K_2 oppodycnvbk oppostanvbk modemst1 modemst2 opporeserve1..3 carrier DRIVER fsg fsc` |

The numbers that matter, all read off the device with `part list`, none guessed:

| Partition | LUN | first LBA | blocks |
| --- | --- | --- | --- |
| `boot` | 4 | `0xc505` | `0x4000` (64 MiB) |
| `recovery` | 4 | `0x1064e` | `0x4000` |
| `dtbo` | 4 | `0x1464e` | `0x1000` |
| `logfs` | 4 | `0x19391` | `0x800` (8 MiB) |
| `vm-system` | 0 | `0x2d00` | `0x8000` (128 MiB) — holds the ESP |
| `userdata` | 0 | `0x198900` | `0xd11ef3` (52.3 GiB) |

LBAs are 4096-byte blocks, not 512: `scsi read` and `part` speak the device's own
block size, and every offset above is in those units.

Two things surprised us here, both worth knowing before reading the code:

- **LUN0's GPT has 32 slots and 14 entries.** `fastboot getvar all` shows the ABL
  knows 64 partitions, and its list, reversed, begins with exactly those same 14
  in the same order. So LUN0 carries a *truncated copy* of the factory table —
  the firmware half lives on LUN4 and LUN5 with tables of its own. Nothing is
  missing; it is spread across the LUNs.
- **`boot` is readable from U-Boot.** `scsi read 0xa0000000 0xc505 1` returns
  `ANDROID!` — the image that is running. That is what makes "flash a payload to a
  named partition, read it back by LBA" a usable development loop.

U-Boot's boot sequence is two lines of environment:

```
bootcmd=echo === uefi boot manager; bootefi bootmgr;
        echo === raw payload: logfs; scsi dev 4; scsi read 0xa0000000 0x19391 400;
        md.b 0xa0000000 16; bootefi 0xa0000000:400000;
        echo === nothing booted, staying at the prompt
```

`bootefi bootmgr` is the normal path: the EFI loader walks block devices, finds
the FAT volume on `vm-system`, runs `\EFI\BOOT\BOOTAA64.EFI`. The second half is
the fallback that made bring-up possible before the ESP existed — a bare PE image
written to `logfs` (8 MiB, unused, safe to overwrite) and started by address.
`bootefi <addr>` alone answers `No UEFI binary known at ...` because it only
accepts addresses the loader itself recorded; the `:<size>` suffix is mandatory
for an image pulled in by `scsi read`.

## Why the ABL needed four attempts

None of the four matched the sibling port, and each failure looked identical from
the outside: the realme logo, no output, no reset.

| Tried | Result |
| --- | --- |
| `gzip(nodtb)` + board DTB + the vendor's six DTBs | stops on the logo |
| `gzip(nodtb)` + board DTB alone | drops straight to fastboot, like an empty `boot` |
| `gzip(nodtb)` + the vendor's six DTBs, entry 0 patched | logo, and the `sleep 15; reset` probe does **not** reboot |
| the same with all six entries patched, `text_offset` fixed to 0 | unchanged |
| `gzip(paint-fb)` + the vendor table — no U-Boot, 300 bytes of assembly | **green screen, red square, reset** |

That last row is the one that mattered. `stub/paint-fb.S` shares nothing with
U-Boot — it writes `0x9c000000` directly and resets through PSCI — and it runs.
So the container shape was right all along and the failure was inside U-Boot.

### The arm64 Image header

`text_offset` in the 64-byte Linux `Image` header U-Boot puts in front of its
payload is computed as `CONFIG_TEXT_BASE - CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE`.
On a position-independent snapdragon build those two disagree — `TEXT_BASE` is 0
while `mach-snapdragon`'s base defaults to `0x80000000` — so the field read
`-0x80000000`, and a bootloader computing `base + text_offset` landed 2 GiB below
anything executable. Neither a kconfig fragment nor `scripts/config` overrides it
reliably, so `build-in-tree.sh` rewrites the two fields in the produced payload
(they are pure data) and fails the build unless the header then reads
`text_offset 0` with `image_size` equal to the payload length.

### The devicetree U-Boot boots with

`fdtdec_setup()` asks `fdt_find_separate()` for the blob, which on
`CONFIG_OF_SEPARATE` is `_end` — the byte right after `u-boot-nodtb.bin`. The
payload used to be `gzip(nodtb)`, so `_end` pointed at RAM garbage, and
`board_fdt_blob_setup()` arrives at

```c
if (!internal_valid && !external_valid)
	panic("Internal FDT is invalid and no external FDT was provided!");
```

with `CONFIG_PANIC_HANG=y` from `qcom-phone.config` — a silent wait before the
console exists.

The payload is therefore `u-boot-nodtb.bin` followed by the board DTB at exactly
its own length, no padding, so `_end` *is* a valid FDT. And the board DTS has to
define the `/memory` node itself: `sdm670.dtsi` ships `memory@80000000` with
`reg = <0 0x80000000 0 0>` and a comment that the bootloader will fill in the
size, but `qcom_parse_memory()` looks up the literal path `/memory` and treats a
zero size as `-ENODATA`.

The framebuffer node also had to move out of `/chosen`, where the shared device tree keeps it.
`dm_scan_fdt()` walks the root's children and recurses only into simple-bus
nodes; `/chosen` has no driver, so a framebuffer nested there is never bound,
`vidconsole` never appears, and on a UART-less handset that is a board which runs
but cannot speak.

### The missing UFS clock gate

With the tree in place U-Boot booted and reached the prompt, but could not read
the disk:

```
gcc@0x100000: unknown clock ID 137!
qcom-ufshcd ufshc@1d84000: Controller enable notify PRE_CHANGE failed: -2
qcom-ufshcd ufshc@1d84000: ufshcd_probe() failed, ret:-2
```

`-2` is `-ENOENT` from `qcom_gate_clk_en()`, which logs `unknown clock ID` when
`priv->data->clks[id].reg == 0`. The table is a sparse designated-initialiser
array, so a missing clock and a clock at register zero are indistinguishable, and
`137` is `GCC_UFS_PHY_RX_SYMBOL_1_CLK` — the clock `sdm710.dtsi` asks for as
`rx_lane1_sync_clk`. `sdm670_clks[]` has `RX_SYMBOL_0` (0x77018) and jumps to
`TX_SYMBOL_0`; the `sdm845_clks[]` table below it has both lanes, the second at
0x770a8, and every other `UFS_PHY` gate in the sdm670 table matches its sdm845
offset. `patches/uboot/0001-clk-sdm670-add-ufs-phy-rx-symbol-1.patch` adds it.

(The `uclass_get_device_by_ofnode failed: -19` lines that accompany it come from
`of_icc_get()`: the UFS node declares `interconnects` and no provider is bound.
`ufs_qcom_probe()` ignores that error. It is noise.)

## Getting XNU up

The kernel is built by `unixnu build kernel`, which needs macOS and Xcode;
`unixnu-kernel.yml` runs it on a macOS runner and publishes the result, because
upstream's own workflow is a build check that uploads text logs only.

Three board-level decisions carry it, all recorded in `board.toml`:

- **`owned_memory_size = 0x20000000`.** DarwinBoot hands XNU a contiguous window
  and defaults to 256 MiB. Asking for the whole `0x7e2c0000` range (1.97 GiB)
  fails with `out of resources` before the kernel starts: DarwinBoot allocates
  from the EFI memory map, and that map is U-Boot's **low** half, where the ABL
  reserved regions end at `0xB8300000`, the frame buffer takes 10 MiB at
  `0x9c000000`, and U-Boot relocates to the top — leaving a little over 1 GiB
  contiguous, shared with the 52 MiB kernel image. 512 MiB is twice the default
  and fits with room to spare. More needs U-Boot's memory node to describe the
  high half first, which is a separate boot-image change.
- **`IONameMatch cpu -> xpu`** in the kernel's `AppleARMCPU` personality: left
  alone, Apple's CPU class matches `cpu0..cpu7` by prefix and panics with "CPU
  configuration in device tree is invalid". `scripts/make-uboot-payload.py`
  rewrites the string in place, and `ArmCpu` then owns `/cpus`.
- **The panic screen stays off.** It is assembled into the padding at the end of
  the kernel text, and this kernel's padding is `0xa30` bytes against `0xa37`
  needed — seven bytes short. The entry probe's stage bars are patched in
  separately and do not depend on it, and the boot-progress console covers the
  same ground once the console is up.

What that produces: `DarwinBoot` loads the kernel and hands over, the kernel
brings up eight CPUs, sets `cntfrq` from the device tree, starts the console —
then idles, because there is no root device. `bsd_init` re-enters
`vfs_mountroot()` every five seconds with `rootdev == NODEV`.

## The root device

`patches/xnu/sweet-ufs-root.patch` is the answer to that, taken from the ios-sweet
project, which boots iOS 16 on this very handset. It adds `bsd/dev/sweet_ufs.c`:
a read-only block driver that leaves the UFS host exactly as U-Boot left it (link
up, HS-GEAR3), takes over the transfer request list, polls SCSI one command at a
time on LUN 0, finds one GPT partition by name, and exposes it as `ufsroot0` /
`rufsroot0` with 512-byte sectors over the device's 4 KiB blocks. All DMA goes
through one physically contiguous allocation; the host is not cache coherent, so
caches are cleaned and invalidated around each command. Writes are refused, so a
failed mount cannot damage anything.

Three adaptations were needed:

| Change | Why |
| --- | --- |
| drop the `#if defined(ARM64_BOARD_CONFIG_SWEET)` guard | this tree builds the BCM2837 machine config, where that macro is undefined and the whole file would compile to nothing |
| the controller address is the constant `0x1d84000` instead of reading a `/sweet-ufs` node | the ADT generator exports only nodes carrying `unixnu,adt-name` |
| probe from `vfs_mountroot()` rather than only from `IOFindBSDRoot` | the panel showed `vfs_mountroot` entered every five seconds with nothing from the driver: `rootdev` was never assigned, so `bdevvp(rootdev, …)` failed before a filesystem was ever asked |

That third one is also where the driver reports. It assigns `rootdev` on success
and pins its verdict on the panel's `stage:` line (`UFS ok: userdata LUN0
0x198900 …`, or `UFS: init failed <errno>`), because everything the driver
`printf`s scrolls away before anyone can read it. The boot-progress hook is a
weak reference — the bootstrap pass of the XNU build links without the kit
archives, and a strong one turns that expected failure into a real one.

Kernel arguments involved: `rd=ufsroot0 ufsroot=userdata`. `userdata` still holds
Android's encrypted filesystem, so the mount itself is expected to fail with
`errno 19` — that is the next thing to solve, not a bug in the driver.

## Board facts used here

Taken from this handset, not from the reference board:

| Item | Value | Source |
| --- | --- | --- |
| ABL identity | `qcom,msm-id = <0x168 0 0x189 0>`, `board-id = <0 0>` | every entry of `firmware/stock-appended-dtbs.bin` |
| Framebuffer | `0x9c000000`, 1080x2340, stride `1080*4`, `a8r8g8b8` | ABL `cont_splash`, the same numbers the iOS port uses |
| Storage | UFS host `0x1d84000`, six LUNs, 4096-byte blocks, no eMMC | `part list`, `getvar all` |
| GIC / timer | GICD `0x17a00000`, GICR `0x17a60000`, 19.2 MHz, vtimer INTID 19 | `UniXNU-sdm710-common`, confirmed by `CLK cntfrq=19200000` on hardware |
| DRAM window | `0x1_0000_0000 + 0x7e2c_0000` (1.97 GiB contiguous above 4 GiB) | the iOS port, which uses the same window |
| Boot image | page 4096, kernel `0x8000`, ramdisk `0x1000000`, tags `0x100`, header v1 | stock `boot.img` |

`firmware/stock-appended-dtbs.bin` is the vendor's appended-DTB area, six FDTs
concatenated with no padding, straight out of the stock `boot.img`. It ships with
the repository because the ABL needs a table it can match by `qcom,msm-id`;
`androidboot.dtb_idx` is *not* passed — the ABL decides. It contains no serial
numbers or calibration data.

## Board specifics

The wiring that makes this board what it is, all measured on the handset:

- **Panel**: 1080x2340, 32-bit `a8r8g8b8`, at `0x9c000000`; drawn by
  simple-framebuffer from the splash the ABL leaves behind.
- **Storage**: UFS at `0x1d84000` — six LUNs, 4096-byte blocks, no eMMC in use.
  Every LBA in this document is in those 4 KiB units.
- **Clocks**: 19.2 MHz Qualcomm XO counter, virtual timer INTID 19; big cores at
  2.3 GHz, GPU at 610 MHz.
- **Keys**: power through the PM660 PON block; volume up/down are assumed to sit
  on PM660L GPIO 7, which the stock DTB has not confirmed yet.

## Next

1. First hardware run of the UFS driver: read its `stage:` line. `UFS ok:` means
   the block device works and what remains is a filesystem; `UFS: init failed
   <errno>` names the stage (5 host handover, 6 no GPT, 2 no such partition,
   12 DMA).
2. Put a mountable root on a partition — a small HFS image first, to prove the
   path, then a real one.
3. Then userland.

## License

GPL-2.0-or-later for the U-Boot pieces (the DTS derives from GPL-2.0 sources and
the board files are U-Boot configuration). See `LICENSE`.
