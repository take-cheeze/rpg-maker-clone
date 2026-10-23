- **bc2cpp** declared-constant, RBS record, RBS parameter and RBS signature
  scans now name their opcodes through the shared `BytecodeIR::Ops` sets and
  `each_with_op` instead of raw opcode-string compares. Generated C++ and
  analysis output are unchanged.
