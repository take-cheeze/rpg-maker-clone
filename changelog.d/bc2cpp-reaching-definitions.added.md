- bc2cpp has a real reaching-definitions query over its bytecode CFG
  (`BytecodeIR.reaching_definitions`). Constant-receiver calls and the
  receiver-class trace use it when their backward walk finds nothing, resolving
  a receiver whose textually last write never reaches the call (a write on an
  arm that returns) or whose constant load sits before a block argument.
