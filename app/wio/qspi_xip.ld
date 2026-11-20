/*
  Copyright (c) 2014-2015 Arduino LLC.  All right reserved.

  This library is free software; you can redistribute it and/or
  modify it under the terms of the GNU Lesser General Public
  License as published by the Free Software Foundation; either
  version 2.1 of the License, or (at your option) any later version.

  This library is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
  See the GNU Lesser General Public License for more details.

  You should have received a copy of the GNU Lesser General Public
  License along with this library; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*/

/* QSPI_XIP: the board's variants/wio_terminal/linker_scripts/gcc/flash_with_bootloader.ld (framework-arduino-samd-seeed),
 * plus the QSPI region and the sections marked QSPI_XIP below. Everything else is unchanged. */

/* Linker script to configure memory regions.
 * Need modifying for a specific board.
 *   FLASH.ORIGIN: starting address of flash
 *   FLASH.LENGTH: length of flash
 *   RAM.ORIGIN: starting address of RAM bank 0
 *   RAM.LENGTH: length of RAM bank 0
 */
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000+0x4000, LENGTH = 0x00080000-0x4000 /* First 16KB used by bootloader */
  QSPI (rx) : ORIGIN = 0x04000000, LENGTH = 0x00400000 /* QSPI_XIP: the external 4 MB flash's AHB window */
  RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 0x00030000
}

/* Linker script to place sections and symbol values. Should be used together
 * with other linker script that defines memory regions FLASH and RAM.
 * It references following symbols, which must be defined in code:
 *   Reset_Handler : Entry of reset handler
 *
 * It defines following symbols, which code can use without definition:
 *   __exidx_start
 *   __exidx_end
 *   __copy_table_start__
 *   __copy_table_end__
 *   __zero_table_start__
 *   __zero_table_end__
 *   __etext
 *   __data_start__
 *   __preinit_array_start
 *   __preinit_array_end
 *   __init_array_start
 *   __init_array_end
 *   __fini_array_start
 *   __fini_array_end
 *   __data_end__
 *   __bss_start__
 *   __bss_end__
 *   __end__
 *   end
 *   __HeapLimit
 *   __StackLimit
 *   __StackTop
 *   __stack
 */
ENTRY(Reset_Handler)

SECTIONS
{
	/* QSPI_XIP (app/wio/src/wio_qspi_xip.c): the bc2cpp-compiled gems' code, read-only data and unwind tables run from
	 * the external flash, which is readable only after the .preinit_array step opens the window. Listed before .text
	 * so these inputs match here first. Only libmruby.a members of the *-compiled gems are named:
	 * scripts/wio/qspi_xip_check.rb checks that every member of those names is one, and that nothing reachable
	 * from Reset_Handler before the window opens lies in this region. The header is qspi_image.py's. */
	.qspi_header :
	{
		/* 32 zero bytes with contents (`. = 32` alone would be NOBITS, and the image would start at .qspi). */
		LONG(0) LONG(0) LONG(0) LONG(0) LONG(0) LONG(0) LONG(0) LONG(0)
	} > QSPI

	.qspi :
	{
		*libmruby.a:*_compiled_gen_shard*.o(.text .text.* .rodata .rodata.* .ARM.extab .ARM.extab.* .gnu.linkonce.armextab.*)
		*libmruby.a:register.o(.text .text.* .rodata .rodata.* .ARM.extab .ARM.extab.* .gnu.linkonce.armextab.*)
		. = ALIGN(4);
	} > QSPI

	.text :
	{
		__text_start__ = .;

		KEEP(*(.sketch_boot))

		. = ALIGN(0x4000);
		KEEP(*(.isr_vector))
		*(.text*)

		KEEP(*(.init))
		KEEP(*(.fini))

		/* .ctors */
		*crtbegin.o(.ctors)
		*crtbegin?.o(.ctors)
		*(EXCLUDE_FILE(*crtend?.o *crtend.o) .ctors)
		*(SORT(.ctors.*))
		*(.ctors)

		/* .dtors */
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

	/* QSPI_XIP: the one unwind index table (it must stay one sorted table) is in the QSPI region too; nothing
	 * unwinds before the window opens. libgcc finds it by __exidx_start/__exidx_end, so the output section has its
	 * own name, which PlatformIO's internal-flash size check (it counts .ARM.exidx) does not count. */
	.qspi_exidx :
	{
		__exidx_start = .;
		*(.ARM.exidx* .gnu.linkonce.armexidx.*)
		__exidx_end = .;
	} > QSPI

	/* QSPI_XIP: after the vector table (.text starts at the bootloader's 0x4000), in internal flash. */
	.note.gnu.build-id :
	{
		__wio_build_id_note = .;
		KEEP(*(.note.gnu.build-id))
	} > FLASH

	/* To copy multiple ROM to RAM sections,
	 * uncomment .copy.table section and,
	 * define __STARTUP_COPY_MULTIPLE in startup_ARMCMx.S */
	/*
	.copy.table :
	{
		. = ALIGN(4);
		__copy_table_start__ = .;
		LONG (__etext)
		LONG (__data_start__)
		LONG (__data_end__ - __data_start__)
		LONG (__etext2)
		LONG (__data2_start__)
		LONG (__data2_end__ - __data2_start__)
		__copy_table_end__ = .;
	} > FLASH
	*/

	/* To clear multiple BSS sections,
	 * uncomment .zero.table section and,
	 * define __STARTUP_CLEAR_BSS_MULTIPLE in startup_ARMCMx.S */
	/*
	.zero.table :
	{
		. = ALIGN(4);
		__zero_table_start__ = .;
		LONG (__bss_start__)
		LONG (__bss_end__ - __bss_start__)
		LONG (__bss2_start__)
		LONG (__bss2_end__ - __bss2_start__)
		__zero_table_end__ = .;
	} > FLASH
	*/

	__etext = .;

	.data : AT (__etext)
	{
		__data_start__ = .;
		*(vtable)
		*(.data*)

		. = ALIGN(4);
		/* preinit data */
		PROVIDE_HIDDEN (__preinit_array_start = .);
		KEEP(*(.preinit_array))
		PROVIDE_HIDDEN (__preinit_array_end = .);

		. = ALIGN(4);
		/* init data */
		PROVIDE_HIDDEN (__init_array_start = .);
		KEEP(*(SORT(.init_array.*)))
		KEEP(*(.init_array))
		PROVIDE_HIDDEN (__init_array_end = .);


		. = ALIGN(4);
		/* finit data */
		PROVIDE_HIDDEN (__fini_array_start = .);
		KEEP(*(SORT(.fini_array.*)))
		KEEP(*(.fini_array))
		PROVIDE_HIDDEN (__fini_array_end = .);

		KEEP(*(.jcr*))
		. = ALIGN(16);
		/* All data end */
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

	/* .stack_dummy section doesn't contains any symbols. It is only
	 * used for linker to calculate size of stack sections, and assign
	 * values to stack symbols later */
	.stack_dummy (COPY):
	{	__StackStart = .;
		*(.stack*)
	} > RAM

	/* Set stack top to end of RAM, and stack limit move down by
	 * size of stack_dummy section */
	__StackTop = ORIGIN(RAM) + LENGTH(RAM);
	__StackLimit = __StackTop - SIZEOF(.stack_dummy);
	PROVIDE(__stack = __StackTop);

	__ram_end__ = ORIGIN(RAM) + LENGTH(RAM) -1 ;

	/* Check if data + heap + stack exceeds RAM limit */
	ASSERT(__StackLimit >= __HeapLimit, "region RAM overflowed with stack")
}
