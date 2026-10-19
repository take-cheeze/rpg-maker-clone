- **bc2cpp** block and yield analyses (YIELD_REACH, BLOCK_SELF_WORLD,
  BLOCK_RETURNS) now read block operands, receivers and captured registers
  through the bytecode IR's reaching definitions instead of the preceding
  instruction, closing escape and name-proof gaps at joins and nested-block
  writes (ADR 0504).
