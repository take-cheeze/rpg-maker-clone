- **bc2cpp**: the core rows proof reads the compiled core code instead of core bytecode, so a core method a compiled
  core body calls directly no longer keeps its table entry, and the proof's annotation comments are no longer read as
  method names. Closed host table 671 → 642 entries.
