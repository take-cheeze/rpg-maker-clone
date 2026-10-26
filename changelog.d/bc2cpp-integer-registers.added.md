- **bc2cpp:** register operands (`Insn#reg`, `#regs`, dataflow queries)
  are Integers end-to-end internally instead of digit Strings; text forms
  (`reg_token`, disassembly, C++ emission) convert at the boundary. Removes
  per-visit `to_i` parsing; `StrictKeyHash`-style silent-mismatch bugs in
  name/opaque sets fixed alongside.
