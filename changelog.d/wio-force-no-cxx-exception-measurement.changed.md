- **Wio Terminal: added a measurement-only, opt-in escape hatch
  (`MRUBY_FORCE_NO_CXX_EXCEPTION`) to force mruby's VM unwinding back to
  `setjmp`/`longjmp` instead of real C++ exceptions, and measured the real
  flash cost of keeping exceptions.** Unset (every normal build, on every
  target), this changes nothing -- it is a no-op by default, not a new
  default. Real, twice-reproduced `pio run -e wio_rgss_boot` link with the
  hatch enabled: FLASH overflow 651,824 -> 631,664 bytes (a real 20,160-byte
  reduction, almost entirely `.ARM.extab`/`.ARM.exidx` unwind-table
  metadata). **Not adopted as the default**: `mruby-rgss`'s own `.cxx`
  sources have live C++ objects (`std::string`/`std::vector`) on their call
  stacks, and `longjmp`-based unwinding skips their destructors entirely,
  leaking heap buffers on every VM-level `raise`/`break`/non-local-`return`
  that passes through such a frame -- a real correctness cost this project
  has not audited or accepted. See ADR 134.
