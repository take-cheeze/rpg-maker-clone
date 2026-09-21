- Fix a second CI failure in the Optcarrot bc2cpp probe: `compiled_run.rb`
  was the one bc2cpp build integration in this repo that never set
  `SKIP_UNSUPPORTED=1` (every other one does --
  `mruby-lcf-compiled`/`mruby-rgss-compiled`/`mruby-rpg2k-compiled`'s
  `mrbgem.rake`, `tools/bc2cpp/wio_registered_methods.rb`, and this same
  directory's own `optcarrot_bc2cpp_coverage_report.rb`). Without it, a
  method bc2cpp can't safely translate (an unmodeled block/`send`-with-block
  construct, `#error unhandled opcode BLOCK`/`SENDB`) leaves that `#error`
  marker in the generated C++ instead of quietly falling back to
  interpreted bytecode for just that method, turning an isolated,
  already-documented fallback into a hard compile failure for the whole
  probe. `compiled_run.rb` now sets it too, matching every other consumer.
