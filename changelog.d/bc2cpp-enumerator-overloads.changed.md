- **bc2cpp** types a blockless Enumerable iterator (`map`, `select`, `each_slice(n)` and
  the rest mruby answers with `to_enum`) on an exact core receiver that includes Enumerable as an
  Enumerator. Their RBS declarations are the method-level union of a blockless
  overload (`Enumerator[untyped, untyped]`) and a block overload (`Array[untyped]`).
  The Enumerator result is a reserved flow bit that names no class (ADR 0524); see
  `docs/bc2cpp-enumerator-results.md`. Checked by `scripts/bc2cpp/enumerator_result_check.rb`.
