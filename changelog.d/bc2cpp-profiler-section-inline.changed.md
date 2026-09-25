- **bc2cpp** now compiles `RGSS::Profiler.section("name") { ... }` and
  `Profiler.frame { ... }` to a direct call around the native profiling
  primitives, removing 21 of the 26 hot-only profiler block fallbacks in
  `mruby-rpg2k`. A same-flags Wio-style object comparison measures 5,901 bytes
  less `.text`. A computed section name, or a body containing `break`, keeps
  the existing fallback. See
  `docs/adr/0232-bc2cpp-profiler-section-inlining.md`.
