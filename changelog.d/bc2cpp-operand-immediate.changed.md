- **bc2cpp**: the signed immediate of a LOADI/ADDI/SUBI-family instruction is read through one accessor,
  `BytecodeIR::OperandModel.imm_operand`, instead of `Insn#imm_operand` at each proof and codegen site. The
  generated output is unchanged byte for byte (checked over every instruction of the compiled gem sources and
  the fixture generator's output).
