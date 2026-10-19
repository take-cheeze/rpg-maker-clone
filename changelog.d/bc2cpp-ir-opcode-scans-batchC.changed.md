- **bc2cpp** (batch C of the raw-opcode scan cleanup): the runtime-definition, core-definition and element-site
  passes read the shared `BytecodeIR` helpers (`op?`, `each_with_op`, `instructions_with_op`, `previous`,
  `instruction_at`) instead of iterating raw instruction arrays for opcode names. Generated C++ is unchanged.
