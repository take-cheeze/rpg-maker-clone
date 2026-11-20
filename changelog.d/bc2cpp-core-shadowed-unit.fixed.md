- **bc2cpp** closed build: a core class body whose def a gem replaces (mruby-enum-ext's `Enumerable#all?`) is
  still run as its class unit, so `Enumerable::NONE` is defined again and loading a save no longer fails with
  `uninitialized constant Enumerable::NONE`. Check `scripts/bc2cpp/core_shadowed_unit_check.rb`.
