- `tools/bc2cpp/bc2cpp.rb`: a callee compiled to decide a devirtualization
  (`compiles_clean?`) now starts from fresh per-method state and restores
  the caller's afterwards. Before, it inherited the caller's in-progress
  block/upvar/self-class state and then cleared part of it, so 10 clean
  methods (e.g. `RPG2k::Scene::Map#pages_changed?`) were cached as unclean
  and 13 call sites stayed on `mrb_funcall`. `Game::State` embedding is
  capped at its current three ivars (`BC2CPP_EMBED_IVAR_LIMITS`) until the
  18 extra ivars have been exercised by a real save/load run. Checked by
  `scripts/bc2cpp_nested_compile_state_check.rb`; see docs/adr/0202.
