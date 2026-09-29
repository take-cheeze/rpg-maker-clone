- bc2cpp reads every instruction operand through typed `Insn` accessors
  (`reg`, `sym`, `argc`, `n_spec`/`nk_spec`, `block_index`, `const_name`, ...); no
  compiler pass scrapes the raw disassembly text any more. The generated C++ is
  byte-identical.
