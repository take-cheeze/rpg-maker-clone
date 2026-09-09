- **Investigated `-fno-exceptions`/`-fno-rtti` for the Wio Terminal build**,
  matching PlatformIO's own Arduino framework compile. This project's own
  C++ (`mruby-rgss`/`mruby-lcf`/`app/wio`) has no `try`/`catch`/`throw`
  anywhere — but mruby's own core exception handling
  (`begin`/`rescue`/`ensure`) compiles as real C++ `throw`/`catch` whenever
  any gem has a C++ source (true here), specifically because `longjmp`
  cannot safely unwind past C++ destructors — a real, load-bearing
  dependency `-fno-exceptions` cannot compile past. `-fno-rtti` separately
  fails on `mruby-rgss/src/lib.cxx`'s own `typeid(T).name()` diagnostic
  label, a smaller, real, unpursued follow-up if that label is ever
  replaced. See ADR 120. No flash/RAM change — the build never completed.
