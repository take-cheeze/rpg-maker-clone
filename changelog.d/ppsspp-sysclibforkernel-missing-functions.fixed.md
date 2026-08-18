- **PPSSPP's `SysclibForKernel` HLE module now implements `strtoul`,
  `strncat`, `memchr`, and `tolower`.** This EBOOT's PSP boot pulls in
  sixteen `SysclibForKernel` imports; PPSSPP's own loader correctly
  recognized all sixteen by NID, but only had HLE handlers for twelve of
  them. Calling one of the missing four (routine calls from mruby's
  vendored core and newlib itself) silently did nothing and returned
  whatever garbage was already in the return-value register instead of
  performing the real operation, rather than raising any visible error at
  the call site — the actual root cause of ADR 0047 P1's bug 8 (three
  earlier passes misdiagnosed this as a PPSSPP JIT bug, then a timing
  race, then a boxed-`mrb_value`/`const char*` type confusion inside
  mruby, before a verbose trace through `psp-fixup-imports`'s own import
  grouping proved those symbol-address cross-references had been reading
  *stale* addresses and pointed at the real cause instead).
  `nix/patches/ppsspp-sysclibforkernel-missing-functions.patch` adds all
  four, matching the existing entries' style (`Memory::IsValid*`-guarded,
  `hleLogVerbose`-wrapped calls into the real host libc function). Not
  yet upstreamed to `hrydgard/ppsspp`. With this fixed, the PSP EBOOT's
  `Unknown syscall` count during boot drops from ~90 to 1 and the `Bad
  memory access` flood bug 8 was named for is gone entirely; boot now
  reaches a new, separate, not-yet-fixed bug (a real mruby GC assertion,
  `gc.c`'s `gc_mark_children` asserting an object it's marking isn't
  actually gray) — see `docs/adr/0047-psp-memory-budget.md`'s P1 for the
  full trail.
