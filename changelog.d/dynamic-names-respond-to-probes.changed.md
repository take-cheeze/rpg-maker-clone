- **bc2cpp** no longer counts a Symbol used only as a `respond_to?` argument
  as a dynamic method name (PROBE_ONLY, `tools/bc2cpp/dynamic_names.rb`). So
  `respond_to?(:battle_row)` no longer costs `Game::Actor#battle_row` and
  `#atb_gauge` their proven Integer returns (TC1010). The rule turns off when
  Ruby code defines, aliases or spells `respond_to?` or `respond_to_missing?`.
