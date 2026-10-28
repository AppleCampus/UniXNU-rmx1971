/*
 * paint-fb: the smallest payload that proves the ABL jumps to what we put in
 * the kernel field.
 *
 * Why: U-Boot never reaches main_loop() on this handset -- the probe
 * environment (sleep 15; reset) never resets, so this is not a display problem,
 * the CPU never reaches bootcmd. Everything between "ABL reads boot.img" and
 * "our code runs" is invisible on a board with no UART, so this stub strips the
 * payload down to nothing that can fail: no DT parsing, no relocation, no
 * stack, no drivers, no libc. It writes pixels into the splash buffer the ABL
 * leaves behind at 0x9c000000, then tries a PSCI reset.
 *
 * The container deliberately copies the working iOS shim on this handset
 * (`rmx1971-shim-boot-gz-m10.img`): a 64-byte Linux arm64 Image header with
 * text_offset = 0 and code at +0x800, padded to 0x2d000 bytes, gzipped, then
 * followed by the vendor's DTB table. U-Boot's own header instead carries
 * text_offset = -0x80000000 (TEXT_BASE 0 minus the snapdragon default base of
 * 0x80000000), which is the difference this image is meant to test.
 *
 * Result reading:
 *   green screen, then the phone reboots by itself
 *            -> ABL jumped, the container shape is right, gzip worked, and PSCI
 *               reset works: whatever still fails after this is inside U-Boot
 *   green screen, no reboot
 *            -> code ran (PSCI reset just is not reachable from here)
 *   logo, but the phone reboots after ~10 s
 *            -> code ran, the panel is no longer scanning out cont_splash
 *   logo and nothing happens, ever
 *            -> ABL never reaches a payload shaped like the known-good one;
 *               compare with the ramdisk (the iOS image has a 16 MiB one) and
 *               with the gzip payload size
 *
 * The framebuffer geometry comes from the ABL splash: 1080x2340, stride 1080*4,
 * a8r8g8b8, carve-out 0x2300000 bytes at 0x9c000000.
 */
	.set	STUB_SIZE, 0x2d000

	.section .text
	.globl	_start
_start:
	b	entry			/* code0: branch to the code, Image style */
	.long	0			/* code1: reserved */
	.quad	0			/* text_offset: load at the 2MB-aligned base */
	.quad	STUB_SIZE		/* image_size: effective size, BSS included */
	.quad	0xa			/* flags: LE | 4K pages | 2MB-aligned base */
	.quad	0
	.quad	0
	.quad	0
	.ascii	"ARM\x64"		/* magic */
	.long	0

	.balign	0x800			/* the kernel convention: code at +0x800 */
entry:
	/* x0 = FDT the ABL handed us; deliberately ignored. */
	movz	x1, #0x9c00, lsl #16		/* x1 <- 0x9c000000, cont_splash */
	movz	x2, #0x9b, lsl #16		/* x2 <- 0x9b0000, >= 1080*2340*4 */

	movz	w3, #0xff00, lsl #16
	movk	w3, #0xff00			/* w3 <- 0xff00ff00, opaque green */

	mov	x4, x1
	add	x5, x1, x2
1:	str	w3, [x4], #4
	cmp	x4, x5
	b.lo	1b

	/* Opaque red 400x400 patch in the top-left corner: it can only appear
	 * once the fill above has run to completion, so a green screen with a
	 * red square is a different (and better) result than plain green. */
	movz	w6, #0xffff, lsl #16		/* w6 <- 0xffff0000, opaque red */
	mov	x7, x1
	mov	x8, #400
2:	mov	x9, #400
	mov	x10, x7
3:	str	w6, [x10], #4
	subs	x9, x9, #1
	b.ne	3b
	add	x7, x7, #4320			/* next row: 1080 * 4 */
	subs	x8, x8, #1
	b.ne	2b

	/* Hold the colour long enough to be seen (~10 s at any plausible clock),
	 * then ask PSCI to reset the board so a test does not need the Vol-Down +
	 * Power chord to come back. 0x2 << 32 iterations, two instructions each. */
	movz	x11, #0x2, lsl #32
5:	subs	x11, x11, #1
	b.ne	5b

	/* The vendor DT advertises /psci method = "smc", i.e. PSCI sits behind EL3;
	 * SMC is routed there from EL2 as well. HVC is deliberately not tried: at
	 * EL2 it would UNDEF (HCR_EL2.HCD) and land in a vector table we never
	 * set, which would look exactly like the hang this stub is meant to rule
	 * out. */
	movz	x0, #0x0009
	movk	x0, #0x8400, lsl #16		/* x0 <- 0x84000009 SYSTEM_RESET */
	smc	#0

4:	wfi
	b	4b

	/* Same total size as the known-good iOS payload, so the ABL sees one. */
	.org	STUB_SIZE
