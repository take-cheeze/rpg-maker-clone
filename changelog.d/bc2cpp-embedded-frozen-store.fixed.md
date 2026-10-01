- **bc2cpp** compiled `SETIV` on an embedded ivar now raises `FrozenError` for
  a frozen object, as `mrb_iv_set` does; the test is dropped in a closed world
  that proves no user object is frozen (ADR 0299, covered by
  `scripts/bc2cpp_embedded_frozen_check.rb`).
