- **The PSP EBOOT now boots to completion under PPSSPP-headless.** The
  last of ADR 0047 P1's nine boot blockers traced back to
  `Core/HLE/sceKernelInterrupt.cpp`'s `sysclib_memset`/`sysclib_memmove`
  — PPSSPP's HLE implementations of PSP's kernel-syscall-backed
  `memset`/`memmove` — returning `0` instead of their destination
  pointer, unlike every sibling pointer-returning function in the same
  file (`sysclib_memcpy`, `sysclib_strcat`, ...) and unlike real C
  `memset()`/`memmove()`. mruby's `mrb_calloc` (used for every GC heap
  page and other core-init structures) does `memset(p, 0, size); return
  p;` — a pattern GCC recognizes and, per its builtin knowledge that a
  standard-conforming `memset()` always returns its first argument,
  optimizes into `return memset(p, 0, size);`. Under PPSSPP's
  non-compliant HLE `memset`, that silently turned every `mrb_calloc`
  call into one returning PPSSPP's wrong `0` instead of the real
  pointer — despite the underlying allocation always succeeding —
  producing a GC heap corrupted from the very first page it ever
  created. `nix/patches/ppsspp-sysclib-memset-memmove-return-value.patch`
  (not yet upstreamed to `hrydgard/ppsspp`) fixes both functions.
  Verified: the identical EBOOT now boots past `mrb_open` (`RPG2K_PSP_
  MRUBY_OPEN ok`) and into the idle `RPG2K_PSP_BRINGUP` heartbeat loop,
  running cleanly for 850,000+ frames with zero errors before the test
  harness's own timeout — see `docs/adr/0047-psp-memory-budget.md`'s P1
  for the full nine-bug trail this closes out.
