- **bc2cpp** runs a literal-block `map`/`each` on an exact Integer-bounded Range
  as a counted loop into the compiled block (RANGE_COLLECT_DIRECT,
  `docs/bc2cpp-collect-direct.md`), where the inlined Range loops do not apply:
  computed bounds and Range loops nested in an inlined loop body. Optcarrot's
  APU noise table no longer builds two Arrays per element through
  Enumerable#collect. Covered by `scripts/bc2cpp/range_collect_direct_check.rb`.
