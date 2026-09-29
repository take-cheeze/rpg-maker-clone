- bc2cpp computes branch targets once (`Insn#branch_target`, `BytecodeIR#jump_edges_before`)
  instead of five hand-rolled JMP/JMPIF case statements and a private edge scan
  in `constant_object_owner`. The generated C++ is byte-identical.
