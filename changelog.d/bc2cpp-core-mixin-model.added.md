- **bc2cpp** models mruby's core mixins: `include Enumerable`/`Comparable` is a
  known ancestor, and `Numeric#positive?`/`#negative?` and
  `Enumerable#min`/`#max` on an exact Array of Integers or Floats are inlined
  behind a guard, verified against the build's own core sources. The
  `module_function` direct call also accepts bodies whose blocks never look at
  `self`, and POLY_TABLE now backs the RGSS wrapper sites past the chain cap
  (76 `update` sites were plain dispatch). Generic POLY sites 467 to 404 on the
  wio closed world (ADR 0261, `scripts/bc2cpp_core_mixins_check.rb`).
