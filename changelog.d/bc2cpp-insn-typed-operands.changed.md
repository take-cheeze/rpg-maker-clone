- bc2cpp decodes symbol, ivar, argument-count, block/pool index, jump address,
  constant-name and `ENTER` operands through typed `Insn` accessors, and
  `compile_send`/`compile_cmp` take an `Insn` instead of the raw operand text.
  The generated C++ is byte-identical.
