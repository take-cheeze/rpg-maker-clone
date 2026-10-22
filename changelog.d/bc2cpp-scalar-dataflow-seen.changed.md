- **bc2cpp** reduces reaching-definition walk allocations by creating per-instruction
  membership hashes only for visits involving multiple registers, preserving traversal
  order, state budgets and refusal diagnostics.
