- Moved `strip_wio_debug_output.rb`, `strip_wio_inline_helpers.rb` and
  `strip_wio_bc2cpp_stubs.rb` from the repo root into `scripts/`, alongside the
  rest of the build/check tooling; `build_config.rb`'s `wio_strip_*` helpers
  now resolve them there. **AGENTS.md** also drops its detailed LCF save-data
  chunk-layout notes, which duplicated documentation better kept near the
  schema/ADRs rather than in agent guidelines.
