- **bc2cpp** closed build: core `Array` includes `Enumerable` again (mruby-rgss's `class Array` reopenings no
  longer drop the core's Array class unit), and `NameError#name`, `NoMethodError#args` and
  `StopIteration#result` exist (mruby's `10error.rb` now runs as class units). Check
  `scripts/bc2cpp/core_own_unit_check.rb`.
