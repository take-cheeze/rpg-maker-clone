/*
 * boot.S -- the entire startup this target needs.
 *
 * QEMU's ARM "-kernel" loader for a plain (non-Linux) ELF jumps straight to
 * the ELF entry point in SVC mode, MMU and caches off, interrupts masked --
 * verified empirically against qemu-system-arm 8.2 (realview-pb-a8,
 * cortex-a8) while building this target, not assumed. That is already
 * exactly the environment this freestanding harness wants: flat physical
 * addressing, and main() never enables interrupts, so there is no vector
 * table to install and nothing else to set up beyond a stack pointer.
 */
.section .text.boot
.global _start
_start:
    ldr sp, =_stack_top
    bl main
1:  b 1b /* main() never returns; loop forever if it somehow does */
