/* DIAGNOSTIC-ONLY: oversized_flash_and_ram_debug.ld with 16 MB of RAM, for
 * env:wio_renode_game_big (scripts/wio/renode_game.bash --board big): a real
 * game's map and battle need more than 4 MB at the Wio build's 32-bit bitmaps.
 * Pair only with wio_terminal_oversized_flash_and_16m_ram.repl.
 */
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000+0x4000, LENGTH = 0x00200000-0x4000
  RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 0x01000000
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
