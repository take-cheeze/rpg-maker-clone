- **bc2cpp: `self` inside a compiled `Array`, `Hash`, `String` or `Range` body is exactly that class** (checked at the
  site, ADR 0381). On the Wio shipped build 54 by-name `bc2cpp_send` sites (`size`, `length`, `keys`, `begin`, `end`,
  `exclude_end?`, ...) in core bodies take the exact-class arm behind one class test whose else is
  `bc2cpp_guard_violation`; the generated C++ grows by 4.7 KB. `BC2CPP_CORE_SELF_EXACT=0` restores the old output.
  Covered by `scripts/bc2cpp_core_self_exact_check.rb`.
