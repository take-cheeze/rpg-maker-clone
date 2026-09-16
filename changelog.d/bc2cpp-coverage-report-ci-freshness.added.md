- CI now guarantees `docs/bc2cpp_coverage.txt` (the stats-only whole-program
  bc2cpp coverage snapshot, `scripts/bc2cpp_coverage_report.rb`) stays in
  sync with reality: nothing previously checked it, so a `tools/bc2cpp/
  bc2cpp.rb` or mrblib change could freely drift the committed numbers with
  no visible signal -- confirmed missing by grepping the whole workflows
  directory before adding this. A new `scripts/bc2cpp_coverage_check.bash`
  regenerates the report against a real, already-built host `mrbc` and
  diffs the result against the committed file (mirroring `scripts/
  check_emscripten_probe_cache.bash`'s own "regenerate and diff" shape),
  wired into the `build` job right after the `cmake --build build` step
  that bootstraps the host `mrbc` it needs. Deliberately does not build its
  own throwaway `mrbc`: the host mruby build's gem set reaches real
  vendored headers (`3rd/stb`'s `stb_image_write.h` among them) that only
  `cmake/build-mruby.cmake`'s own include paths resolve, confirmed by a
  real standalone `rake` invocation failing on exactly that header --
  hand-duplicating that setup would be a maintenance/drift risk this
  codebase's own tooling comments elsewhere explicitly avoid.
  `scripts/bc2cpp_coverage_report.rb`'s own `REPORT_PATH` is now overridable
  via `BC2CPP_COVERAGE_REPORT_PATH` so the check can regenerate into a
  throwaway file without mutating the tracked one. Verified for real: a
  deliberately corrupted `docs/bc2cpp_coverage.txt` is caught and reported
  with an actionable diff and regeneration command; the real file (already
  current after this session's optional-arg devirtualization round, whose
  262 newly-devirtualized call sites all fall outside the specific owner
  classes this report's `ONLY_OWNERS` scope covers) passes clean.
