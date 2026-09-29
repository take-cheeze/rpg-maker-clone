- bc2cpp parses every instruction once, at load, into typed operands with a
  per-opcode schema (`tools/bc2cpp/operand_schema.rb`); `Insn` accessors read those
  operands, so no compiler pass reads the disassembly text. A new
  `bc2cpp_operand_schema_check.rb` round-trips every instruction of the closed-world
  gems against the schema. The generated C++ is byte-identical.
