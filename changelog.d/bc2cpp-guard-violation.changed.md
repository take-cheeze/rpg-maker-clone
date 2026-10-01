- **bc2cpp closed-world builds** no longer dispatch from the else arm of a guard
  on a stable class constant (`Klass.new` identity, `is_a?`/`kind_of?` class
  test, `Klass === x`): 307 sites in the wio build now log
  `[RPG2k] closed-world guard violation: ...` to `$stderr` and raise
  `BC2cppGuardViolation` (a `NoMethodError`). `BC2CPP_GUARD_VIOLATION=0` and
  `-DBC2CPP_GUARD_VIOLATION_DISPATCH` restore the dispatch;
  `-DBC2CPP_NOMETHOD_VERIFY` aborts. See
  `docs/adr/0290-bc2cpp-guard-violation.md`; covered by
  `scripts/bc2cpp_guard_violation_check.rb`.
