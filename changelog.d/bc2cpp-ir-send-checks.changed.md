- **bc2cpp** send codegen reads IR facts instead of re-deriving them: the
  closed-world self-receiver test asks `BytecodeIR.reaching_definitions` for
  LOADSELF writers (no longer only an immediately preceding LOADSELF), the
  loop-element reassignment test and the GETIV/SETIV name scans are cached per
  irep, and `recognize_exec_fallback_regions` runs once per method.
