- **bc2cpp** (ADR 0467): the per-method bytecode facts NumericFlow decoded for itself (successor lists, the
  instructions a handler catches, rescue-only handler targets, the instruction decode) now live on
  `BytecodeIR::Program`, and the call-facts flow, the origin walk and the record-hash alias scan read them from there.
  The generated code is unchanged.
