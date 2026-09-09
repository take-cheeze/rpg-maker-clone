- **Wio Terminal: stripped the dev-only profiler/Chrome-trace exporter.**
  `mruby-rgss/src/profiler.cxx` (frame/section timing, memory sampling,
  the `RGSS::Profiler` Ruby module) was compiled and initialized
  unconditionally on every target, but nothing on wio ever enables it --
  no `--profile` flag, no Ruby game script reaching `RGSS::Profiler`.
  Gated the real implementation behind the same `WIO_TERMINAL` macro
  `terminal.cxx` already uses for its own desktop-only backend; a minimal
  stand-in keeps every call site wio actually reaches working unchanged.
  Real ARM cross-compile of this one file: 9,926 -> 102 bytes of `.text`.
  See ADR 125.
