- **Wio Terminal: `mruby-time` is no longer linked, saving 15.5 KB of
  flash.** The board has no set real-time clock. F8 bug reports on wio are
  now named by frame count, and a wio build that names `Time` anywhere in
  the engine's Ruby now fails (`scripts/strip_wio_clock.rb`, ADR 0221).
