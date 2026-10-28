- **The closed build leaves unreachable core methods out of mruby's ROM method
  tables.** The registration proof now also lists the core C natives
  (`MRB_MT_ENTRY`) that no symbol, string or presym use in the program, the
  native sources or the generated code can name. The list is
  `tools/bc2cpp/static_dispatch_core_excluded.rb`. `build_config.rb` passes it
  to the closed build as the `MRB_MT_EXCLUDE_HEADER` that mruby's fork now
  reads, and `3rd/mruby` moves to that fork commit. Core natives registered at
  run time are listed by the same rule and removed by mruby-core-compiled. A
  verify build stubs each listed name instead. See "Core ROM entries" in
  `docs/bc2cpp-unregistered-methods.md`.
