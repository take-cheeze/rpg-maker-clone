- bc2cpp decodes jump targets through a typed `Insn#jump_target` that ignores
  the disassembly's trailing local-variable comment, so constant-receiver calls
  after keyword-argument branches resolve statically and `BytecodeIR` keeps those
  branch edges.
