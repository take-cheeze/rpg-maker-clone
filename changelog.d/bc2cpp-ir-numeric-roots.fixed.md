- `BC2CPP_NUMERIC_ROOTS` (`tools/bc2cpp/codegen_numeric_roots.rb`) takes each operand's leaves from the bytecode IR's
  reaching definitions instead of a private "nearest writer plus later loop writers" list. The old list missed writes
  that reach a read through a join, a loop back edge or a handler, and counted writes that cannot reach it; a
  register written in a nested block is now reported as `unproven` rather than omitted. Measured on the shipped
  pass, 1,986 of 2,627 rows change. Generated C++ is unchanged (ADR 0509).
