- bc2cpp builds predecessor edges once in `BytecodeIR` (with `JMPUW` and the
  `RET*` ops modelled, dangling jumps flagged unresolved) and the Fixnum proof reads
  them from there instead of keeping its own predecessor map.
