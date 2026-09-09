# 120. Attempted: -fno-exceptions for wio

Date: 2026-09-09

## Status

Accepted (a real, honestly-reported negative result -- see Consequences)

## Context

Looking for further omittable code patterns: PlatformIO's own Arduino
framework build for this board already compiles with `-fno-exceptions
-fno-rtti` (`platformio.ini`'s own comment on this, found earlier this
session while chasing an unrelated link error), but this rake-driven
`libmruby.a` never matched it. Grepped every `.cxx` this gem set actually
compiles (`mruby-rgss/src`, `mruby-lcf/src`, `app/wio/src`) for
`try`/`catch`/`throw`: none, anywhere -- a real, checked fact, not an
assumption, and reason enough to try it for real.

## Decision

**Tried it, reverted it.** Added `-fno-exceptions` to wio's cc/cxx flags
(positioned *after* `rpg_maker_gems(conf)`, since mruby's own gem loader,
`lib/mruby/build/load_gems.rb`, auto-calls `enable_cxx_exception` the
moment any gem has a `.cxx` source -- true here for
`mruby-rgss`/`mruby-lcf`/`mruby-marshal` -- appending its own
`-fexceptions` that would otherwise win the last-flag-on-the-command-line
conflict). It does not compile: mruby's own core exception handling
(`MRB_TRY`/`MRB_CATCH`, `include/mruby/throw.h`), compiled as C++
specifically because `MRB_USE_CXX_EXCEPTION` auto-enables whenever any
C++ gem is present, implements Ruby's own `begin`/`rescue`/`ensure` as
*real* C++ `throw`/`catch` rather than `setjmp`/`longjmp` -- deliberately,
because `longjmp` does not run C++ destructors and would leak or corrupt
any C++ object on the stack being unwound through. `-fno-exceptions`
fails even mruby's own `error-cxx.cxx` (`'e' was not declared in this
scope` inside `MRB_CATCH`'s own macro expansion) before this project's
own code is ever reached.

A separate, smaller thing was tried alongside it and also reverted:
`-fno-rtti` fails to compile `mruby-rgss/src/lib.cxx`, whose
`DataType<T>::data_type` uses `typeid(T).name()` for each C-data-wrapped
Ruby class's (`Color`, `Tone`, `Table`, `Bitmap`, ...) diagnostic type
label. Real, if narrow, RTTI use -- unlike exceptions, not load-bearing for
mruby's own core, so a real (smaller) candidate on its own if that one
label is ever worth replacing with a manually-supplied name instead of
`typeid`. Not pursued further this round.

## Consequences

- Nothing about this project's own C++ has an unnecessary exceptions
  dependency -- the check that made this worth trying (no try/catch/throw
  anywhere in `mruby-rgss`/`mruby-lcf`/`app/wio`) was correct. What makes
  `-fno-exceptions` unusable here is one level down, in how this specific
  build configuration (any mrbgem set mixing C and C++) makes mruby
  implement its *own* exception handling. A pure-C mruby build (no C++
  gems at all) would not have this constraint; this project's build, with
  `mruby-rgss`/`mruby-lcf` both C++, does.
- `-fno-rtti` remains a real, separate, smaller candidate --
  `DataType<T>::data_type`'s `typeid(T).name()` is the one blocker, fixable
  by supplying each instantiation's name explicitly instead of relying on
  RTTI for it. Not done here; a future pass's first step if pursued.
- No flash/RAM numbers to report -- the build never got past compilation,
  so nothing was measured, and nothing in the committed tree changed
  functionally (just a documentation note at the point in `build_config.rb`
  future readers doing the same search would look).
