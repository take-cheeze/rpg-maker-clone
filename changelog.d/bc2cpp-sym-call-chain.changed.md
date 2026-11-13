- **bc2cpp:** the per-element call of an inlined `&:sym` loop now compiles
  like an ordinary call site (`SYM_CALL_CHAIN`): `map(&:name)` and
  `each(&:dispose)` call each element's method directly instead of looking
  it up by name.
