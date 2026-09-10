# 134. Measurement-only escape hatch to force mruby off C++ exceptions on wio

Date: 2026-09-10

## Status

Accepted (as a measurement tool only -- default wio build behavior unchanged)

## Context

Asked directly how much flash a forced switch from real C++-exception-based
VM unwinding back to `setjmp`/`longjmp` would recover.

mruby has two ways to implement `MRB_TRY`/`MRB_CATCH`/`MRB_THROW` (used to
unwind the VM on a Ruby-level `raise`, `break`, `next`, or non-local
`return`): plain `setjmp`/`longjmp`, or -- when
`MRB_USE_CXX_EXCEPTION` is defined -- real C++ `throw`/`catch` of a
`mrb_jmpbuf*` pointer (`include/mruby/throw.h`; the catch is an identity
comparison, `if (e != (buf)) throw e;`, not general exception handling).
The C++ path exists specifically so that a VM-level unwind which passes
through a live C++ stack frame runs that frame's destructors correctly;
`longjmp` does not run destructors at all, so any `std::string`/`std::vector`
(or similar RAII object) left on a stack being unwound through leaks its
heap buffer instead of freeing it. `mruby-rgss`'s own `.cxx` sources have
real C++ objects on their call stacks, so this is not a hypothetical risk
on this project's own code -- a prior session in this series already
concluded real exceptions are load-bearing for this build for exactly this
reason.

mruby's own build system decides which path to use, and offers no existing
lever to override it: `lib/mruby/build/load_gems.rb` unconditionally calls
`enable_cxx_exception` the moment `gem` loads any gem with a `.cpp`/`.cxx`/
`.cc` source (`mruby-rgss`, `mruby-lcf`, and `mruby-marshal` all have one
here), which in turn makes `tasks/core.rake` compile mruby's own
`vm.c`/`error.c`/`gc.c` as C++ rather than C. `build.rb`'s
`enable_cxx_exception`/`disable_cxx_exception` pair isn't usable as a
one-line override either: calling `enable_cxx_exception` a second time
after `disable_cxx_exception` raises `"cxx_exception disabled"` rather than
silently no-op'ing, so the only real lever is preventing the first call
from ever firing.

## Decision

Added a new environment-variable escape hatch, `MRUBY_FORCE_NO_CXX_EXCEPTION`,
following the same no-op-by-default convention already used by
`RGSS_WIO_STUB_HEADERS`/`RGSS_WIO_ARDUINO_INCLUDES`:

- **`patches/mruby-force-no-cxx-exception-escape-hatch.patch`** (new, applied
  to the `3rd/mruby` submodule by `cmake/build-mruby.cmake` the same way as
  the project's 7 other mruby-core patches): changes `load_gems.rb`'s
  `enable_cxx_exception unless cxx_srcs.empty?` to also skip when
  `ENV['MRUBY_FORCE_NO_CXX_EXCEPTION']` is set. Unset (every normal build,
  on every target), this is a byte-for-byte no-op.
- **`build_config.rb`**: the wio cross-build's `cc`/`cxx` flags gain
  `-fno-exceptions`, gated behind the same environment variable -- once
  `load_gems.rb` has kept `MRB_USE_CXX_EXCEPTION` from ever being defined,
  compiling mruby's own core (now plain C++ with no exception use) and
  `mruby-rgss`/`mruby-lcf`/`mruby-marshal`'s `.cxx` files with exceptions
  fully disabled at the compiler level shrinks unwind-table metadata
  further than just skipping the `throw`/`catch` codegen would alone.

## What was verified

A full clean rebuild with `MRUBY_FORCE_NO_CXX_EXCEPTION=1` set for both the
`MRUBY_TARGET=wio rake` step and the standalone `uni-algo` cross-build,
followed by `rm -rf .pio/build/wio_rgss_boot` and a real `pio run -e
wio_rgss_boot` link. Confirmed via the generated preprocessed output that
`MRB_USE_CXX_EXCEPTION` was absent and `vm.c`/`error.c`/`gc.c` compiled as
plain C (no `-cxx`-suffixed intermediate objects), then reproduced the link
result twice from a clean state:

```
before (ADR 133, real C++ exceptions): region `FLASH' overflowed by 651824 bytes
after  (MRUBY_FORCE_NO_CXX_EXCEPTION=1 + -fno-exceptions):
         region `FLASH' overflowed by 631664 bytes
```

**A real, twice-reproduced 20,160-byte reduction.** `.ARM.extab` dropped
from 3,156 to 12 bytes and `.ARM.exidx` from 10,112 to 160 bytes -- almost
all of the win is unwind-table metadata, not code, consistent with the
change being purely about how unwinding is implemented rather than what the
VM does.

## Consequences

- **This is not enabled by default, and is not expected to become the
  default without further work.** The correctness risk is real, not
  theoretical, on this project's own code: any VM-level unwind that passes
  through an `mruby-rgss`/`mruby-lcf`/`mruby-marshal` C++ stack frame
  holding a live `std::string`, `std::vector`, or similar RAII object would
  leak that object's heap buffer under `longjmp`-based unwinding, on every
  such unwind for the life of the process -- not a one-time cost, and not
  something a flash-constrained device can necessarily absorb by just
  having more RAM to leak into.
- Using this hatch for real would require auditing every `.cxx` file in
  `mruby-rgss`/`mruby-lcf`/`mruby-marshal` for C++ objects that could be
  live across a `raise`/`break`/non-local-`return` unwind point, and fixing
  or eliminating each one first (e.g. by keeping such state in C-compatible
  storage while a Ruby call is in flight, or by proving no unwind can reach
  that frame at all). That audit has not been done, and is out of scope for
  this ADR, which only answers "how much flash would this recover" as asked.
- If that audit is ever done and the hatch is adopted for real, wiring it
  into `platformio.ini`'s own `build_flags` for `env:wio_rgss_boot` (so
  Arduino-framework/LVGL objects compiled outside `build_config.rb`'s reach
  pick up `-fno-exceptions` too) is still required -- this measurement only
  exercised the `libmruby.a`/`uni-algo` side of the link.
- 20,160 bytes is real but small next to the 651,824-byte overflow left
  after ADR 133 -- this alone does not get `wio_rgss_boot` closer to
  fitting in any way that changes the project's structural conclusion:
  closing the gap needs the SD-external-bytecode loader from ADR 108, not
  more compiler-level tricks.
