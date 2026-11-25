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

/* QSPI_XIP: framework-arduino-samd-seeed's variants/wio_terminal flash_with_bootloader.ld plus the external QSPI
 * flash, executed in place at 0x04000000. app/wio/qspi_xip.py links with it (WIO_QSPI_XIP=0 keeps the board's own)
 * and writes the qspi_xip_*.ld fragments it INCLUDEs from app/wio/qspi_xip_placement.txt. */

MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000+0x4000, LENGTH = 0x00080000-0x4000 /* First 16KB used by bootloader */
  RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 0x00030000
  /* The code image's room at the start of the 4 MB chip; the game ROM starts after it (__wio_game_rom_base), so a
   * firmware build leaves a programmed game ROM where it was. */
  QSPI (rx) : ORIGIN = 0x04000000, LENGTH = 0x00180000
}

ENTRY(Reset_Handler)

SECTIONS
{
	/* The vector table, then what qspi_xip_placement.txt pins to internal flash. Statement order decides where an
	 * input section matching several patterns goes (the first match wins), so the pins come before the QSPI
	 * patterns and the catch-all .text_rest after them. */
	.text :
	{
		__text_start__ = .;

		KEEP(*(.sketch_boot))

		. = ALIGN(0x4000);
		KEEP(*(.isr_vector))
		INCLUDE qspi_xip_internal.ld
	} > FLASH

	/* QSPI_IMAGE_HEADER (app/wio/src/wio_qspi.h): zeros here, filled in after the link by qspi_xip.py. */
	.qspi_header :
	{
		__qspi_image_start = .;
		LONG(0) LONG(0) LONG(0) LONG(0) LONG(0) LONG(0) LONG(0) LONG(0)
	} > QSPI

	.qspi_text :
	{
		INCLUDE qspi_xip_text.ld
	} > QSPI

	.qspi_rodata :
	{
		INCLUDE qspi_xip_rodata.ld
	} > QSPI

	/* The unwind tables are only read by a throw, which runs after the window opens. The index is one table, sorted
	 * by address across both regions (scripts/wio/qspi_xip_check.rb checks it). */
	.ARM.extab :
	{
		*(.ARM.extab* .gnu.linkonce.armextab.*)
	} > QSPI

	.ARM.exidx :
	{
		__exidx_start = .;
		*(.ARM.exidx* .gnu.linkonce.armexidx.*)
		__exidx_end = .;
	} > QSPI

	__qspi_image_end = .;
	__wio_game_rom_base = ORIGIN(QSPI) + LENGTH(QSPI);

	.text_rest :
	{
		/* EXIDX_ORDER (app/wio/exidx_merge.py) */
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

	/* The firmware's identity, which the QSPI image header repeats (wio_qspi_xip.c). */
	.note.gnu.build-id :
	{
		__wio_build_id_note = .;
		KEEP(*(.note.gnu.build-id))
	} > FLASH

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
