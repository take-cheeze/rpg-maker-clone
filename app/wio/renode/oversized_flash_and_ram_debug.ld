/* DIAGNOSTIC-ONLY, not a real hardware config: widens BOTH FLASH and RAM
 * far past the real seeed_wio_terminal board's real budgets (512 KB
 * flash/16 KB bootloader reserved, 192 KB RAM) -- see
 * app/wio/renode/oversized_flash_debug.ld's own comment for the FLASH
 * side. RAM.LENGTH here is widened from the real 0x30000 (192 KB) to
 * 0x400000 (4 MB) so docs/adr/0135's real RAM-exhaustion crash (a real
 * ATSAMD51 chip's own 192 KB does not fit wio_rgss_boot's own setup())
 * does not recur while measuring how much RAM setup() actually needs to
 * finish. Never flashable/loadable on a real board; pair only with
 * app/wio/renode/wio_terminal_oversized_flash_and_ram.repl and the
 * wio_rgss_boot_heapdbg_ram PlatformIO environment (board_build.ldscript).
 * Based verbatim on framework-arduino-samd-seeed's variants/wio_terminal/
 * linker_scripts/gcc/flash_with_bootloader.ld with only the FLASH and RAM
 * regions' LENGTH changed.
 */
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000+0x4000, LENGTH = 0x00200000-0x4000
  RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 0x00400000
}

ENTRY(Reset_Handler)

SECTIONS
{
	.text :
	{
		__text_start__ = .;

		KEEP(*(.sketch_boot))

		. = ALIGN(0x4000);
		KEEP(*(.isr_vector))
		*(.text*)

		KEEP(*(.init))
		KEEP(*(.fini))

		*crtbegin.o(.ctors)
		*crtbegin?.o(.ctors)
		*(EXCLUDE_FILE(*crtend?.o *crtend.o) .ctors)
		*(SORT(.ctors.*))
		*(.ctors)

 		*crtbegin.o(.dtors)
 		*crtbegin?.o(.dtors)
 		*(EXCLUDE_FILE(*crtend?.o *crtend.o) .dtors)
 		*(SORT(.dtors.*))
 		*(.dtors)

		*(.rodata*)

		KEEP(*(.eh_frame*))
	} > FLASH

	.ARM.extab :
	{
		*(.ARM.extab* .gnu.linkonce.armextab.*)
	} > FLASH

	__exidx_start = .;
	.ARM.exidx :
	{
		*(.ARM.exidx* .gnu.linkonce.armexidx.*)
	} > FLASH
	__exidx_end = .;

	__etext = .;

	.data : AT (__etext)
	{
		__data_start__ = .;
		*(vtable)
		*(.data*)

		. = ALIGN(4);
		PROVIDE_HIDDEN (__preinit_array_start = .);
		KEEP(*(.preinit_array))
		PROVIDE_HIDDEN (__preinit_array_end = .);

		. = ALIGN(4);
		PROVIDE_HIDDEN (__init_array_start = .);
		KEEP(*(SORT(.init_array.*)))
		KEEP(*(.init_array))
		PROVIDE_HIDDEN (__init_array_end = .);

		. = ALIGN(4);
		PROVIDE_HIDDEN (__fini_array_start = .);
		KEEP(*(SORT(.fini_array.*)))
		KEEP(*(.fini_array))
		PROVIDE_HIDDEN (__fini_array_end = .);

		KEEP(*(.jcr*))
		. = ALIGN(16);
		__data_end__ = .;

	} > RAM

	.bss (NOLOAD):
	{
		. = ALIGN(4);
		__bss_start__ = .;
		*(.bss*)
		*(COMMON)
		*(COMMON*)
		. = ALIGN(4);
		__bss_end__ = .;
	} > RAM

	.heap (COPY):
	{
		__end__ = .;
		PROVIDE(end = .);
		*(.heap*)
		__HeapLimit = .;
	} > RAM

	.stack_dummy (COPY):
	{	__StackStart = .;
		*(.stack*)
	} > RAM

	__StackTop = ORIGIN(RAM) + LENGTH(RAM);
	__StackLimit = __StackTop - SIZEOF(.stack_dummy);
	PROVIDE(__stack = __StackTop);

	__ram_end__ = ORIGIN(RAM) + LENGTH(RAM) -1 ;

	ASSERT(__StackLimit >= __HeapLimit, "region RAM overflowed with stack")
}
