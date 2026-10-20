- **bc2cpp** types a blockless `map`/`collect` on an exact Array or Hash as an
  Enumerator. Their RBS declarations are the method-level union of a blockless
  overload (`Enumerator[untyped, untyped]`) and a block overload (`Array[untyped]`).
  The Enumerator result is a reserved flow bit that names no class (ADR 0522); see
  `docs/bc2cpp-enumerator-results.md`. Checked by `scripts/bc2cpp/enumerator_result_check.rb`.
