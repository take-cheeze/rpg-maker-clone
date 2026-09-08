/*
 * link.ld -- a flat, MMU-less image for QEMU's realview-pb-a8 machine.
 *
 * 0x70010000 sits inside that machine's RAM bank (0x70000000-0x77ffffff,
 * confirmed via QEMU's own `info mtree`), comfortably clear of nothing else
 * -- this target is the only thing in the address space, there is no
 * bootloader or OS below it to avoid colliding with.
 */
ENTRY(_start)

SECTIONS {
  . = 0x70010000;
  .text : { *(.text.boot) *(.text*) }
  . = ALIGN(4);
  .rodata : { *(.rodata*) }
  . = ALIGN(4);
  /* The two exported map files, embedded as linked binary blobs (see
   * scripts/nano7_qemu_build.bash's objcopy step) -- this target has no
   * filesystem at all, deliberately (docs/adr/0103): skipping SD/FAT
   * emulation entirely is exactly the kind of feature this harness exists
   * to not need. objcopy -I binary lands each blob in its own .data
   * section, hence the wildcard here rather than a named one. */
  .data : { *(.data*) }
  . = ALIGN(4);
  .bss : { *(.bss*) *(COMMON) }
  . = ALIGN(16);
  . = . + 0x40000; /* 256 KiB stack -- this target has nothing else to spend RAM on */
  _stack_top = .;
}
