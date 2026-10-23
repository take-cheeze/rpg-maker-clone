- The bc2cpp code generator's receiver, send, rescue, numeric-root, loop-region and frozen-table passes now read
  instructions through the bytecode IR (`BytecodeIR.for(irep).source_at`, `each_source`) instead of indexing
  `irep.instructions` directly. Generated C++ is unchanged.
