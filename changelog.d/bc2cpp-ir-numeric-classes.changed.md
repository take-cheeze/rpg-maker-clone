- **bc2cpp** NumericFlow, the numeric class-mask flow, now reads its
  instruction operands, frame exits and the literal-element proof from the
  bytecode IR (ADR 0493). The element proof answers from reaching definitions,
  so a literal element written further before its Array literal, or on joined
  arms, is now proven too.
