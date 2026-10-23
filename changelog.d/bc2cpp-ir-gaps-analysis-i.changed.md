- The bc2cpp block capture lookup, context-result binding layout, DEF body
  lookup, symbol-flow state cap and ivar reflection scan in `tools/bc2cpp`
  read instructions through the bytecode IR (`BytecodeIR.for(irep)`) instead
  of `irep.instructions`; `CoreDefs.def_body_label` takes the index its
  callers already have instead of searching for the instruction. The block
  capture and ivar candidate checks build ireps the IR can load. Generated
  C++ is unchanged.
