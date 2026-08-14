- **PSP build strips mruby bytecode debug info.** `enable_debug` was adding
  `-g` to `mrbc`'s compile options for the PSP cross-build, embedding
  line-number/local-variable debug tables in every gem's compiled mrblib
  bytecode. Unlike native C debug symbols (file size only, never mapped into
  RAM), `mrb_load_irep` parses these into live heap structures at boot —
  measured at roughly 240-350 KB of live RAM for the rpg2k+lcf+rgss mrblib
  stack, against a 4 MB LVGL pool that may have to cover mruby's whole heap.
  `build_config.rb`'s `psp` cross-build now strips it back out, the same way
  it already strips `enable_debug`'s `-O0`. See
  `docs/adr/0047-psp-memory-budget.md` (Finding 5), which also confirms `-O0`
  and native `-g3` were never actually live problems for this target — an
  earlier pass at that research got the `-O0` part wrong.
