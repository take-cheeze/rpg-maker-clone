- **bc2cpp** inlines `Integer#step`, `#upto` and `#downto` loops whose receiver, limit and
  step are provably Integers (literals or proven fixnum expressions) into the method's own
  frame, like `#times`; a Float operand, a zero step or an unproven operand keeps the block
  call. Checked against the interpreter by `scripts/bc2cpp_step_inline_check.rb`
  (ADR 0273).
