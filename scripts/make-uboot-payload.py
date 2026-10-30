#!/usr/bin/env python3
r"""Finish the payload volume: add the loader chain to the image "unixnu build payload" wrote.

The unixnu payload step writes a FAT volume holding \EFI\UniXNU\unixnu.toml, the prelinked
kernel and its ADT sidecar. On a board whose UEFI is Mu-Silicium the firmware volume carries
UniXNU.efi and DarwinBoot.efi instead, so the payload needs nothing more. This board's UEFI is
its own U-Boot, which has no firmware volume of ours to put them in: U-Boot's EFI boot manager
looks for \EFI\BOOT\BOOTAA64.EFI on the volumes it can read, so the volume has to carry the
whole chain:

  \EFI\BOOT\BOOTAA64.EFI                UniXNU.efi    the boot manager application
  \EFI\UniXNU\unixnu.toml               written by "unixnu build payload"
  \EFI\UniXNU\Payloads\DarwinBoot.efi   the XNU loader driver unixnu.toml names
  \EFI\UniXNU\Payloads\kernel.macho     the prelinked kernel
  \EFI\UniXNU\Payloads\kernel.macho.adt the device tree UniXNU hands to XNU

Two edits are made to the kernel on the way in, both required by this board:

  * the entry probe (stage bars on the frame buffer), patched by the tree's
    scripts/patch-xnu-entry-probe.py with --no-reset. board.toml sets panic_screen = false
    because this kernel's padding is seven bytes too small for the panic screen, but the
    probe bars are independent of it and are the only way to see how far an early boot got.
  * the AppleARMCPU personality's IONameMatch, rewritten from "cpu" to "xpu" so the Apple
    CPU class stops claiming /cpus before the native ArmCpu does.

Usage:
  make-uboot-payload.py --payload out/rmx1971/payload/payload.img \
      --unixnu-efi Build/Out/AARCH64-DEBUG/UniXNU.efi \
      --darwinboot-efi Build/DarwinBoot/DEBUG_CLANGPDB/AARCH64/DarwinBoot.efi \
      --entry-probe tree/scripts/patch-xnu-entry-probe.py \
      --output rmx1971-payload.img

The finished image is flashed to the vm-system partition (LUN0 entry 8, LBA 0x2d00, 128 MiB):

  fastboot flash vm-system rmx1971-payload.img

and U-Boot's boot manager starts it, because the main environment runs "bootefi bootmgr" first.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

KERNEL_IN_VOLUME = '::/EFI/UniXNU/Payloads/kernel.macho'


def run_mtool(argv, check=True):
    """Run an mtools command without a controlling terminal.

    mtools opens /dev/tty for its prompts; a caller in a CI job without a console is then
    stopped by SIGTTOU instead of failing. setsid plus a closed stdin keeps it headless.
    """
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    command = (['setsid'] if shutil.which('setsid') else []) + argv
    result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if check and result.returncode:
        raise SystemExit(f'{" ".join(argv)} failed: {result.stdout}')
    return result


def neutralize_apple_cpu(data):
    """Rewrite the AppleARMCPU IONameMatch in place; data is a bytearray of the kernel.

    AppleARMPlatform.kext ships an AppleARMCPU class whose personality is
    IONameMatch = "cpu" with probe score 100. IODTPlatformExpert compares names by prefix,
    so "cpu" also matches this board's cpu0..cpu7 nodes; its start then validates an
    Apple-shaped /cpus (max_cpus, cpu-id, interrupts, function-*) and panics with "CPU
    configuration in device tree is invalid" on a non-Apple tree. The native ArmCpu owns the
    cores instead. "xpu" has the same length, so nothing in the image moves.

    The bundle id appears in several plists, so take the occurrence whose dictionary actually
    carries the CPU match rather than the first one in the image.
    """
    needle = b'<key>IONameMatch</key><string>cpu</string>'
    window = -1
    seen = False
    anchor = data.find(b'<key>AppleARMCPU</key>')
    while anchor >= 0:
        seen = True
        candidate = data.find(needle, anchor, anchor + 600)
        if candidate >= 0:
            window = candidate
            break
        anchor = data.find(b'<key>AppleARMCPU</key>', anchor + 1)
    if not seen:
        raise SystemExit('AppleARMCPU personality not found in the prelinked kernel')
    if window < 0:
        if b'<key>IONameMatch</key><string>xpu</string>' in data:
            print('AppleARMCPU personality: already neutralised (xpu)')
            return
        raise SystemExit('AppleARMCPU IONameMatch is not in the expected form')
    at = window + len(b'<key>IONameMatch</key><string>')
    data[at:at + 3] = b'xpu'
    print('AppleARMCPU personality: IONameMatch cpu -> xpu (the native ArmCpu owns /cpus)')


def patch_kernel(image, probe_script):
    """Apply the entry probe and the CPU personality fix, in one extract/copy cycle."""
    with tempfile.TemporaryDirectory() as tmp:
        kernel = Path(tmp) / 'kernel.macho'
        run_mtool(['mcopy', '-n', '-o', '-i', str(image), KERNEL_IN_VOLUME, str(kernel)])
        if probe_script:
            # The probe patch writes the stage-bar branches into the kernel's own text, so it
            # has to run on the file. --no-reset because a reset in the middle of bring-up
            # throws away the screen we are trying to read.
            result = subprocess.run([sys.executable, str(probe_script), str(kernel), '--no-reset'],
                                    capture_output=True, text=True)
            if result.returncode:
                raise SystemExit(f'{probe_script} failed:\n{result.stdout}\n{result.stderr}')
            for line in (result.stdout or '').strip().splitlines()[-3:]:
                print(f'entry probe: {line}')
        data = bytearray(kernel.read_bytes())
        neutralize_apple_cpu(data)
        kernel.write_bytes(data)
        run_mtool(['mcopy', '-o', '-i', str(image), str(kernel), KERNEL_IN_VOLUME])


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--payload', type=Path, required=True, help='the payload.img of "unixnu build payload"')
    parser.add_argument('--unixnu-efi', type=Path, required=True, help='UniXNU.efi (package/build.sh output)')
    parser.add_argument('--darwinboot-efi', type=Path, required=True, help='DarwinBoot.efi (build-darwinboot.sh output)')
    parser.add_argument('--entry-probe', type=Path, default=None, help="the tree's patch-xnu-entry-probe.py")
    parser.add_argument('--output', type=Path, default=None, help='copy the finished image here')
    args = parser.parse_args()

    for path in (args.payload, args.unixnu_efi, args.darwinboot_efi):
        if not path.is_file():
            raise SystemExit(f'{path} not found')
    for path in (args.unixnu_efi, args.darwinboot_efi):
        if path.read_bytes()[:2] != b'MZ':
            raise SystemExit(f'{path} is not a PE image')
    if args.entry_probe and not args.entry_probe.is_file():
        raise SystemExit(f'{args.entry_probe} not found')

    image = args.payload
    stage = image.parent / 'uboot-stage'
    shutil.rmtree(stage, ignore_errors=True)
    (stage / 'EFI/BOOT').mkdir(parents=True)
    (stage / 'EFI/UniXNU/Payloads').mkdir(parents=True)
    shutil.copyfile(args.unixnu_efi, stage / 'EFI/BOOT/BOOTAA64.EFI')
    shutil.copyfile(args.darwinboot_efi, stage / 'EFI/UniXNU/Payloads/DarwinBoot.efi')
    run_mtool(['mcopy', '-i', str(image), '-s', '-o', '-Q', '-m', str(stage / 'EFI'), '::/'])
    shutil.rmtree(stage)

    patch_kernel(image, args.entry_probe)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(image, args.output)
        image = args.output

    print(run_mtool(['mdir', '-i', str(image), '-/', '::']).stdout)
    print(f'payload volume ready: {image} ({image.stat().st_size >> 20} MiB)')
    print('flash it with:')
    print(f'  fastboot flash vm-system {image.name}')


if __name__ == '__main__':
    main()
