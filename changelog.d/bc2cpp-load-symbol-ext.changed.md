- The closed-world (`closed`) build now loads `mruby-symbol-ext`, so `Symbol`
  includes `Comparable` and has `casecmp`, `casecmp?`, `upcase`, `downcase`,
  `capitalize` and `empty?` in the compiled closed world, as
  `sig/bc2cpp/declarations.rbs` and mruby's own sources already assume. The gem
  was missing from the build's gem list (`build_config.rb`), and its mrblib was
  missing from the bc2cpp core-mrblib list (`tools/bc2cpp/compiled_gems.rb`).
