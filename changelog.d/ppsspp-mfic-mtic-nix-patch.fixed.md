- **`flake.nix`'s `ppsspp` package carries a second local patch, alongside the
  existing LwMutex one: the interpreter's `mfic`/`mtic` (Allegrex "move
  from/to interrupt controller") were pure no-ops.** PPSSPP already tracks an
  `interruptsEnabled` flag for the equivalent `sceKernelCpuSuspendIntr`/
  `ResumeIntr` syscalls, with accessors already exported for exactly this —
  `mfic`/`mtic` just never got wired to it. pspsdk's own
  `pspSdkDisableInterrupts()`/`EnableInterrupts()` are built directly on these
  two instructions instead of the syscall, to guard its own non-reentrant C
  runtime state without syscall overhead; with them doing nothing, those
  critical sections gave no real protection under PPSSPP — a timer/thread
  interrupt could land in the middle of what pspsdk's runtime believed was
  atomic. Found on the same PSP-boot investigation as the LwMutex patch (see
  `docs/adr/0047-psp-memory-budget.md`'s P1 section) — a real, independent
  correctness gap, though not by itself enough to get the EBOOT booting. Not
  yet upstreamed to `hrydgard/ppsspp`; `nix/patches/
  ppsspp-mfic-mtic-interrupt-mask.patch` applies it locally, same as the
  LwMutex one.
