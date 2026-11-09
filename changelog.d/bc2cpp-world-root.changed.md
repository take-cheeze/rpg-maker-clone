- bc2cpp: its own tree (`tools/bc2cpp`, `scripts/bc2cpp`, the optcarrot probe, the runner gems) and the repository it
  compiles (`3rd/mruby`, the engine gems, `build_config.rb`, `sig/bc2cpp`) are separate roots, `BC2CPP_TREE_ROOT` and
  `BC2CPP_WORLD_ROOT` (`tools/bc2cpp/world_root.rb`, `tools/bc2cpp_tree.rb`), so bc2cpp can run from another
  repository: the first step of moving it to nfcxx. Nothing changes while both are this checkout.
