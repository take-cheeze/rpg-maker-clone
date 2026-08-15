- The executable's remaining `stderr` `fprintf` calls in `src/main.cxx`
  (project-detection failure, the Emscripten `rpg_start_game`/frame-loop
  messages, and the "waiting for a project" notice) now go through ng-log's
  `LOG()` macros like the rest of the engine's logging, so they honor the
  same severity filtering and get mirrored into the on-screen terminal log
  console. The `mruby-rgss`/`mruby-mvjs` gem-side `fprintf` calls are left
  as-is per ADR 0005's constraint that those gems (also linked into
  `mrbtest`, the PSP build, and the Wio Terminal firmware) stay free of a
  compile-time dependency on ng-log.
