- bc2cpp now lowers mruby `OP_CMP` integer and float tag pairs directly,
  while preserving Ruby dispatch for other operand types and `OP_EQ` identity
  semantics.
