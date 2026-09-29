- **bc2cpp** now compiles the last four methods that stayed on the interpreter:
  a `break` inside a `begin ... rescue` loop (`JMPUW`), a rescue whose join
  returns another register (`LCF::Array2D#read_row_bytes`), integer literals
  wider than 32 bits (`LOADL` bigint pool entries, rebuilt from their digits so
  32-bit `mrb_int` targets are unaffected), and a `yield` inside a protected
  range. `n.times { ... }` without a block parameter is inlined instead of
  building a Proc. See `docs/adr/0260-bc2cpp-fallback-bodies.md`.
