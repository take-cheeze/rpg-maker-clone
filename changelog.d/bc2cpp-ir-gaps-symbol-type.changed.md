- **bc2cpp** analysis scans (block-self, symbol flow, integer constants, type feedback, context results) read
  instructions through the bytecode IR (`BytecodeIR.for(irep)`: `each_source`, `each_with_op`, `source_at`,
  `branch_target_addrs`) instead of raw `irep.instructions`. Generated C++ is unchanged.
