- **`psp-fixup-imports` now repoints tail calls, not just `jal`.** The patched
  tool reorders import stubs and rewrites the call sites that target them, but
  scanned only for `jal`. MIPS also has `j`, which the compiler emits for a
  tail call — any function whose last act is calling the import, such as LVGL's
  delay hook `void delay_cb(uint32_t ms) { sceKernelDelayThread(ms * 1000); }`,
  which compiles to a bare `j` with no `jal` anywhere. This EBOOT has 49 such
  sites against 1642 `jal`s, and all 49 were left aimed at pre-reorder
  addresses, silently invoking whichever import the regroup left there. Because
  the stub table moves with the binary, the same tail call landed on
  `sceIoRemove` in one build and `sceIoDread` in another: LVGL's once-per-frame
  *timing* call surfaced as a once-per-frame *filesystem* syscall with the
  19000μs delay reinterpreted as a path pointer, and could land somewhere fatal
  whenever unrelated code shifted the layout — which is why adding a few lines
  of diagnostics could turn a working boot into an emulator crash, and why this
  looked like layout-sensitive memory corruption for so long. Nothing was
  corrupt; the call went elsewhere. Fixed by accepting `MIPS_OP_J` alongside
  `MIPS_OP_JAL` — the rewrite already preserves the opcode field. Verified:
  `delay_cb` now resolves to `sceKernelDelayThread`, the per-frame bogus
  `sceIoRemove`/`sceIoDread` calls drop to zero, and 212623 real delays are
  issued across a 1066-heartbeat run.
