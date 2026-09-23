- **bc2cpp** `tools/bc2cpp/bc2cpp.rb` is split into part files
  (`irep.rb`, `registry.rb`, `ivar_layout.rb`, `annotations.rb`,
  `element_layouts.rb`, `codegen*.rb`, ...) that it loads with
  `require_relative` in the original definition order. The move is purely
  mechanical: `scripts/bc2cpp_split.rb` generates it and checks the Prism ASTs
  of every definition and the load-time reference order, and the generated C++
  of all three compiled gems is byte-identical, open- and closed-world.
