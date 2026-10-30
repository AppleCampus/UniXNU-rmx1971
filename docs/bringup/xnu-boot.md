# Getting XNU to run: memory window and kernel patches

Three things have to be right before the kernel keeps running. All three are
board policy in `board.toml` or a build-time patch; none of them touch the XNU
sources.

## The owned memory window

DarwinBoot hands XNU one contiguous window and takes it from the EFI memory map.
When `[payload.adt] owned_memory_size` is unset the default is 256 MiB.

Measurements on this handset:

| `owned_memory_size` | Result |
| --- | --- |
| unset (256 MiB) | boots; panel shows `MEM totalMiB=256`, `wired=21203` |
| `0x7e000000` (1.97 GiB) | kernel never starts: `rmx1971 first boot returned: out of resources` |
| `0x20000000` (512 MiB) | boots; `MEM totalMiB=512`, `wired=22411` |

`out of resources` is `EFI_OUT_OF_RESOURCES` from `AllocatePages`. The map is
U-Boot's low half (`0x8000_0000 + 0x7e2c_0000`), where the ABL reservations end at
`0xB8300000`, the frame buffer holds 10 MiB at `0x9c000000`, and U-Boot relocates
to the top — leaving a little over 1 GiB contiguous, shared with the 52 MiB kernel
image. The high half declared by `dts/rmx1971.dts` is not in that map at all.

512 MiB is the value the port ships. More requires U-Boot's memory node to
describe the high half first, which is a boot-image change.

## `IONameMatch cpu` → `xpu`

The kernel's `AppleARMCPU` personality matches `/cpus` children by name prefix.
Left alone it claims `cpu0..cpu7` and panics with `CPU configuration in device
tree is invalid`. `scripts/make-uboot-payload.py` rewrites the string in place
(same length, so nothing in the image moves), and the board's `ArmCpu` driver owns
`/cpus` instead.

## The panic screen does not fit

`scripts/patch-xnu-entry-probe.py` assembles a panic screen into the padding at
the end of the kernel text. This kernel's padding is `0xa30` bytes and the screen
assembles to `0xa37`, so the step refuses to write it and `board.toml` sets
`panic_screen = false`.

The entry probe (two coloured bars at the top of the screen, one on kernel entry
and one after the MMU is on) is patched separately with `--no-reset` and does not
depend on the panic screen. It is what makes an early hang visible on a machine
with no serial port.

## Kernel arguments

```
-v debug=0x14e kt_fixed_zones=120 ml-timeout-lock-panic-scale=40 -no_slto_panic
boot-progress=2 sheng-smp=1 cpus=8 armcpu-self-ipi=1 armcpu-timer-intid=19
sheng-pmgr=2 amfi_get_out_of_my_way=1 rd=ufsroot0 ufsroot=userdata
```

`boot-progress=2` turns on the full diagnostic panel; `sheng-pmgr=2` advertises
the `ApplePMGRNub` AMFI looks for; `rd=ufsroot0` selects the board's UFS root
device (see [ufs-root.md](ufs-root.md)).

## Where it currently stops

`bsd_init` reaches `vfs_mountroot()`, fails, and retries every five seconds. The
kernel is healthy at that point: eight CPUs online, counter rate matching the
device tree, console drawing. It is waiting for a root device that does not exist
yet, and every sampled PC lands on `_machine_idle`.
