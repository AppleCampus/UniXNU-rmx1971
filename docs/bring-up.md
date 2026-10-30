# Bring-up record

Device observations for the RMX1971 port, in the order they were made. Each entry
names the image that produced it, so a claim can be re-checked by flashing the
same bytes. The panel dumps are transcribed from photographs of the screen: this
handset has no UART, so the framebuffer is the only log transport there is.

Image hashes are SHA-256 of the file that was written with `fastboot flash`.

## 2026-10-29 — U-Boot reaches its prompt

Image: `uboot-rmx1971-boot.img`, `6d539972…`.

```
U-Boot 2026.07-ga2...           dirty (Oct 28 2026 - 16:..)
Model: Realme 5 Pro (RMX1971)
qcom-ufshcd ufshc@1d84000: uclass_get_device_by_ofnode failed: -19
qcom-ufshcd ufshc@1d84000: error finding src node
qcom-ufshcd ufshc@1d84000: invalid ref_clk setting = 0
qcom-ufshcd ufshc@1d84000: [RX, TX]: gear=[3, 3], lane[1, 1], pwr[FAST MODE, FAST MODE], rate = 2
Net:   No ethernet found.
GENI-SE: GENI SE wrapper not found
RMX1971 U-Boot
scanning bus for devices...
```

Both conditions for this milestone: the payload's arm64 `Image` header carries
`text_offset = 0`, and the board DTB sits at `_end` so `fdtdec_setup()` finds a
tree. Before those two, the same image produced the realme logo and nothing else.

`gear=[3, 3] lane=[1, 1] rate = 2` is HS-GEAR3 rate B: the UFS link is up at full
speed, which is what makes the next entry possible.

## 2026-10-29 — six LUNs, and `boot` is readable

```
Device 0: (0:0) Capacity: 60072.0 MB = 58.6 GB (15378432 x 4096)
Device 1: (0:1) Capacity: 4.0 MB (1024 x 4096)
Device 2: (0:2) Capacity: 4.0 MB (1024 x 4096)
Device 3: (0:3) Capacity: 32.0 MB (8192 x 4096)
Device 4: (0:4) Capacity: 656.0 MB (167936 x 4096)
Device 5: (0:5) Capacity: 256.0 MB (65536 x 4096)
```

63.99 GB in total, and every LUN carries its own GPT. LUN0's table has 32 slots
and 14 entries (`ssd persist misc keystore frp vm-keystore vm-data vm-system
vm-linux cache system vendor odm userdata`); `fastboot getvar all` shows the ABL
knows 64 partitions, and its list reversed starts with those same 14. The firmware
half lives on LUN4 and LUN5.

The measurement that turned storage from a question into a tool:

```
part start scsi 4 boot   -> 0xc505
scsi read 0xa0000000 0xc505 1
a0000000: 41 4e 44 52 4f 49 44 21 9a a5 2b 00     ANDROID!..+.
```

U-Boot reads the partition the ABL boots it from. `0xc505` × 4096 = 0x0c505000,
and `0x4000` blocks is 64 MiB, matching `partition-size:boot: 0x4000000` from
`getvar all`.

## 2026-10-29 — the UEFI chain, one link at a time

| Step | Evidence |
| --- | --- |
| `bootefi bootmgr` finds the ESP | payload volume on `vm-system` (LUN0 entry 8, LBA 0x2d00, 128 MiB FAT32), `\EFI\BOOT\BOOTAA64.EFI` = `UniXNU.efi` |
| `UniXNU.efi` runs | with no `unixnu.toml` it fell back to its built-in four-item menu (`Return to firmware` / `Restart` / `Power off` / `Tools`) |
| it reads a real config | after a `unixnu.toml` was added, the title changed to the configured string and the first entry became the configured one |
| it starts a payload | `hello.efi` printed its three lines and returned to the menu — handoff through UniXNU's own loader, not U-Boot's `bootefi` |

Intermediate step worth keeping: before the ESP existed, a PE image on `logfs`
(LUN4 LBA 0x19391, 8 MiB, unused) was started with
`bootefi 0xa0000000:400000`. The size suffix is mandatory — `bootefi <addr>`
alone answers `No UEFI binary known at 0xa0000000` because it only accepts
addresses the EFI loader itself recorded.

## 2026-10-29 — XNU starts

Image: `rmx1971-payload.img`, `65c5952d…`.

```
TOPO boot=0 max=7 nums=01234567|DT cfg=1 cpu=8 dev=1 bus=1 nv=1
PROBE calls=17 acc=8 dtype=9 dnum=0 smp=1 num=7 boot=0 reg=700 tl=8 rl=32
MEM totalMiB=256 free4K=44286 active=0 inactive=0 wired=21203 speculative=0
RAMDISK sparse=0 capacityMiB=0 residentKiB=0
SMP req=1 run=0 cond=1 boot=0 | c1=step4 ... c7=step4
CLK cntfrq=19200000 dt-timebase=19200000 dt-converted=59641ms cntfrq-converted=59641ms (equal)
TIMER vct=4e6dab14 cval=4e6e8ae7 ctl=1 DAIF=200
```

Eight CPUs, the 19.2 MHz counter agreeing with the device tree, the panel drawn
by the kernel itself. `MEM totalMiB=256` was the tell: `owned_memory_size` was
unset, so DarwinBoot used its default.

Sampled PCs decoded against `kernel.macho`'s `LC_SYMTAB`:

| PC | Symbol |
| --- | --- |
| `0xfffffff0073f3b74` | `_machine_idle + 0xfc` |
| `0xfffffff0073e5864` | `_machine_track_platform_idle + 0x2c` |
| `0xfffffff0073f31b4` | `_ml_set_interrupts_enabled` |

Every sample on an idle path, with `root=0 procs=0`: the kernel was not crashed,
it was waiting for a root device.

## 2026-10-29 — memory: 512 MiB, and why not 1.97 GiB

| `owned_memory_size` | Result |
| --- | --- |
| unset (256 MiB) | boots, `MEM totalMiB=256` |
| `0x7e000000` (1.97 GiB) | **never reaches the kernel**: UniXNU reports `rmx1971 first boot returned: out of resources` |
| `0x20000000` (512 MiB) | boots, `MEM totalMiB=512`, `wired=22411` |

`out of resources` is DarwinBoot's `EFI_OUT_OF_RESOURCES`: the window is
allocated from the EFI memory map, which is U-Boot's low half
(`0x8000_0000 + 0x7e2c_0000`), where the ABL reserved regions end at
`0xB8300000`, the frame buffer takes 10 MiB at `0x9c000000`, and U-Boot
relocates to the top. The high half the device tree declares is not in that map
at all.

## 2026-10-30 — the kernel reaches `vfs_mountroot`

Image: `rmx1971-payload.img`, `9a5cfc18…`.

```
stage: pid=0 kernel_task bsd_init: calling setconf?
 6s pid=0 kernel_task bsd_init: vfs_mountroot?
 6s pid=0 kernel_task vfs_mountroot enter
 6s pid=0 kernel_task bsd_init: calling setconf?
11s pid=0 kernel_task bsd_init: vfs_mountroot?
11s pid=0 kernel_task vfs_mountroot enter
```

A five-second retry loop: `bsd_init` calls `vfs_mountroot()`, it fails, the loop
repeats. No message from the driver and no panic, which is what led to reading
`bsd/vfs/vfs_subr.c`: `vfs_mountroot()` starts with
`bdevvp(rootdev, &rootvp)`, and `rootdev` was `NODEV` because
`IOFindBSDRoot()` is never reached on this path. The UFS driver is therefore
probed from `vfs_mountroot()` itself now, and assigns `rootdev` on success.

## Pending

The first boot with the UFS driver probing from `vfs_mountroot()` and reporting on
the `stage:` line. Two outcomes matter: `UFS ok: userdata LUN0 0x198900 …` means
the block device works and the remaining problem is a filesystem, while
`UFS: init failed <errno>` names the stage (5 host handover, 6 no GPT, 2 no such
partition, 12 DMA).
