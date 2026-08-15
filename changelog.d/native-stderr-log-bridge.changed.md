- The remaining native (non-Ruby) `fprintf(stderr, ...)` diagnostics in
  `mruby-rgss`/`mruby-mvjs` — a font-load failure (`mruby-rgss/src/lib.cxx`),
  a trace-file-open failure (`mruby-rgss/src/profiler.cxx`), MV's WOFF/WOFF2
  font-load warnings (`mruby-mvjs/src/mvcanvas.cxx`) and MZ's WebGL `warn()`
  helper (`mruby-mvjs/src/mvgl.cxx`) — now also reach ng-log through the same
  bridge the Ruby `$stderr` diagnostics use. Each site still writes to the
  real `stderr` first, unconditionally, so `mrbtest`, the PSP build and the
  Wio Terminal firmware keep exactly the visibility they had before; only the
  desktop/wasm executable additionally routes the line through
  `LOG(WARNING)`. Left alone: the profiler's per-interval stats line (live
  telemetry, not a diagnostic), the embedded JS engine's `console.log`
  passthrough, and the `[MV-THUMB]`-fenced screenshot protocol line — none of
  these are logging.
