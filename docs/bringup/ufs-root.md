# Storage: UFS, and the root device

RMX1971 stores on UFS (`ufshc@1d84000`, UFSHCI 2.1). There is no eMMC controller
in use, which is why none of the shared SDCC1 code applies. Details that cost time
to establish are below; the partition map itself is in the README.

## The missing clock gate (U-Boot)

Without the patch in `patches/uboot/`, `ufshcd` fails before it can talk to the
device:

```
gcc@0x100000: unknown clock ID 137!
qcom-ufshcd ufshc@1d84000: Controller enable notify PRE_CHANGE failed: -2
qcom-ufshcd ufshc@1d84000: ufshcd_probe() failed, ret:-2
```

`-2` is `-ENOENT` from `qcom_gate_clk_en()`, which logs `unknown clock ID` when
`priv->data->clks[id].reg == 0`. The table is a sparse designated-initialiser
array, so a clock that is missing and a clock whose enable register sits at zero
look identical. `137` is `GCC_UFS_PHY_RX_SYMBOL_1_CLK`, the clock `sdm710.dtsi`
requests as `rx_lane1_sync_clk`. `sdm670_clks[]` has `RX_SYMBOL_0` (`0x77018`) and
jumps straight to `TX_SYMBOL_0`; the `sdm845_clks[]` table below it has both lanes,
the second at `0x770a8`, and every other `UFS_PHY` gate matches its sdm845 offset.
The patch adds that one entry.

The `uclass_get_device_by_ofnode failed: -19` lines printed alongside come from
`of_icc_get()`: the UFS node declares `interconnects` and no provider is bound.
`ufs_qcom_probe()` ignores the error.

## Six LUNs, not one

`ufshcd` enumerates six LUNs totalling 63.99 GB. LUN0 carries Android's
fourteen-partition GPT; the firmware half lives on LUN4 and LUN5 with tables of
their own. `fastboot getvar all` lists 64 partitions, and its list reversed begins
with LUN0's fourteen in the same order — LUN0's table is a truncated copy, not a
different layout.

Two measurements that turn the device into a usable development loop:

```
part start scsi 4 boot   -> 0xc505
scsi read 0xa0000000 0xc505 1
a0000000: 41 4e 44 52 4f 49 44 21   ANDROID!
```

U-Boot reads the partition the ABL boots it from, by fixed LBA. A payload on a
named partition can therefore be verified from inside the firmware.

## The XNU side: `patches/xnu/sweet-ufs-root.patch`

A read-only block driver (`bsd/dev/sweet_ufs.c`) that leaves the host exactly as
U-Boot left it — link up, HS-GEAR3 — takes over the transfer request list, polls
SCSI one command at a time on LUN 0, finds one GPT partition by name
(`ufsroot=`, default `userdata`) and exposes it as `ufsroot0` / `rufsroot0`, with
512-byte sectors over the device's 4 KiB blocks. All DMA goes through one
physically contiguous allocation; the host is not cache coherent, so caches are
cleaned and invalidated around each command. Writes are refused, so a failed mount
cannot modify anything.

Three adaptations were needed for this tree:

| Change | Why |
| --- | --- |
| guard `#if defined(ARM64_BOARD_CONFIG_SWEET)` removed | this tree builds the BCM2837 machine config, where the macro is undefined and the file would compile to nothing |
| controller address is the constant `0x1d84000`, not a `/sweet-ufs` node | the ADT generator exports only nodes carrying `unixnu,adt-name` |
| probed from `vfs_mountroot()`, not only from `IOFindBSDRoot` | see below |

## Why the probe sits in `vfs_mountroot()`

The first version added a branch inside `IOFindBSDRoot()`. Nothing ran: the panel
showed `vfs_mountroot` entered every five seconds with no driver output and no
panic, which means the branch was never reached.

`bsd/vfs/vfs_subr.c`:

```c
if ((error = bdevvp(rootdev, &rootvp))) { ... return error; }
```

`rootdev` was still `NODEV`, so `bdevvp()` failed before any filesystem was asked.
The probe therefore lives at the top of `vfs_mountroot()`, which is provably
reachable, and it assigns `rootdev` on success instead of only reporting.

Two details worth keeping:

- the driver pins its verdict on the panel's `stage:` line (`UFS ok: userdata LUN0
  0x198900 …` or `UFS: init failed <errno>`), because the console pane keeps seven
  lines and everything a driver prints scrolls away;
- the boot-progress hook is a weak reference. The bootstrap pass of the XNU build
  links without the kit archives, and a strong reference turns that expected
  failure into a real one.

`errno` meanings: 5 host handover, 6 no GPT, 2 no such partition, 12 DMA.

`userdata` still holds Android's encrypted filesystem, so the first successful
probe is expected to fail the mount with `errno 19`. That is the next problem, not
a driver bug.
