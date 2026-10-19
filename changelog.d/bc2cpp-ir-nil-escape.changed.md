- **bc2cpp**: NIL_NARROWING and ESCAPE_ANALYSIS run on the bytecode IR. Nil
  narrowing tracks available register copies through the dataflow instead of
  walking instructions backward, so a test now narrows every copy of the
  tested value (ADR 0505, `docs/bc2cpp-ir-nil-escape.md`).
