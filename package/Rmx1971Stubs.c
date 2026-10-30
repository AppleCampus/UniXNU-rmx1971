/* Inert definitions of the board-probe symbols the diagnostic kit references.
 *
 * BootProgress.c reaches two hardware kits as weak imports: it mirrors every
 * console character to a CDC-ACM USB console (the shared layer's kit) and, at level 2,
 * prints the USB bring-up and SDCC1 eMMC counters. Neither applies here:
 * RMX1971 stores on UFS, so there is no SDCC1 driver to report from, and the
 * USB console is a bring-up device this port has not got to yet.
 *
 * They cannot simply be left out. A missing weak data symbol resolves to
 * address zero and the panel reads it, and boot_progress_putc() calls
 * rmx1971_usb_log_char() on the first character the kernel prints, so an
 * unresolved import is an immediate panic before anything is visible. Defining
 * them here keeps the diagnostic build intact and inert, which is what the
 * first boot on a new board wants: no poking at registers nobody has mapped.
 *
 * Replace each with the real thing when it exists -- a UFS log writer for this
 * board, or a USB console once DWC3 is up.
 */

typedef unsigned int u32;

volatile u32 rmx1971_usb_step;
volatile u32 rmx1971_usb_gcc;
volatile u32 rmx1971_usb_smmu;
volatile u32 rmx1971_usb_dwc;
volatile u32 rmx1971_usb_dsts;
volatile u32 rmx1971_usb_clk;
volatile u32 rmx1971_usb_pll;

void rmx1971_usb_log_char(char c)
{
	(void)c;
}

void rmx1971_usb_poll(void)
{
}

volatile unsigned int rmx1971_emmc_step;
volatile unsigned int rmx1971_emmc_version;
volatile unsigned int rmx1971_emmc_caps;
volatile unsigned int rmx1971_emmc_state;
volatile unsigned int rmx1971_emmc_clock;
volatile unsigned int rmx1971_emmc_power;
volatile unsigned int rmx1971_emmc_halts;
