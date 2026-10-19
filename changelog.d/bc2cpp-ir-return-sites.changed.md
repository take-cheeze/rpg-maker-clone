- **bc2cpp** return and receiver class analyses (the Fixnum, Array and class
  return proofs, the declared-return check and the exact-class return table)
  read a body's exits and returned-value definitions from the bytecode IR
  instead of their own instruction walks. `x rescue y` keeps its nil source,
  and an early `return` of a register no longer breaks a later dominance
  proof. See `docs/bc2cpp-ir-return-sites.md` and ADR 0503.
