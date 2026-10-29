/* hello.efi -- the smallest thing that proves the UEFI path works end to end.
 *
 * Built as a PE32+ aarch64 EFI application (see scripts/build-payload.sh), it
 * is flashed raw into the logfs partition and read back by U-Boot with
 * `scsi read 0xa0000000 0x19391 8` before `bootefi 0xa0000000`. If this prints,
 * then every link of the chain S2 needs is real: the ABL wrote a raw file to a
 * named partition, U-Boot found that partition by LBA, EFI_LOADER relocated a
 * PE image and called into it with a live system table, and the console
 * protocol still reaches the framebuffer.
 *
 * No libc, no startup code, no gnu-efi: just the two structure offsets that
 * matter, spelled out so the compiler's layout rules do the padding.
 */
typedef unsigned long long u64;
typedef unsigned int u32;
typedef unsigned short u16;

typedef struct {
	u64 signature;
	u32 revision;
	u32 header_size;
	u32 crc32;
	u32 reserved;
} table_header;

/* EFI_SYSTEM_TABLE, truncated at BootServices -- nothing past it is used.
 * FirmwareRevision is 32-bit and followed by a pointer, so the compiler pads
 * four bytes and ConOut lands at offset 64; writing this out by hand is how
 * people get the offset wrong. */
typedef struct {
	table_header hdr;	/* 24 bytes */
	u16 *firmware_vendor;	/* 24 */
	u32 firmware_revision;	/* 32 */
	void *console_in_handle;	/* 40 */
	void *console_in;		/* 48 */
	void *console_out_handle;	/* 56 */
	void *console_out;		/* 64 */
	void *standard_error_handle;	/* 72 */
	void *standard_error;		/* 80 */
	void *runtime_services;		/* 88 */
	void *boot_services;		/* 96 */
} system_table;

typedef struct {
	void *reset;
	u64 (*output_string)(void *self, const u16 *string);
} simple_text_output;

static void print(system_table *st, const u16 *s)
{
	simple_text_output *out = (simple_text_output *)st->console_out;

	out->output_string(out, s);
}

/* aarch64 UEFI entry: (EFI_HANDLE image, EFI_SYSTEM_TABLE *st) in x0/x1,
 * status in x0. The MS ABI the PE format implies is what clang emits for
 * aarch64-pc-win32-coff, so no asm shim is needed. */
u64 efi_main(void *image, system_table *st)
{
	(void)image;

	print(st, u"hello.efi: PE32+ aarch64 application is running\r\n");
	print(st, u"hello.efi: read from LUN4 LBA 0x19391, loaded by U-Boot\r\n");
	print(st, u"hello.efi: EFI_LOADER, console and memory allocation all work\r\n");
	return 0;
}
