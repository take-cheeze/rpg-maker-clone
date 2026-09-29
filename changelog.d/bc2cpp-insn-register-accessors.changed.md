- bc2cpp reads an instruction's first and all register operands through typed
  `Insn#reg`/`Insn#regs` instead of per-call-site regexes over the disassembly text.
