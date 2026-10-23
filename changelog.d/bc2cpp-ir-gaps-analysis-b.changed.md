- The bc2cpp analyses in `tools/bc2cpp` (block yield types, block operands and
  captures, block returns, dispatch targets, optional-argument tables) read
  instructions through the bytecode IR (`BytecodeIR.for(irep)`) instead of
  indexing `irep.instructions` directly. Generated C++ is unchanged.
