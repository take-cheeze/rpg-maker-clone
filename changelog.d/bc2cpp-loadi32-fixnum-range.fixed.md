- `tools/bc2cpp/bc2cpp.rb`'s Fixnum-operand proof no longer treats every
  `LOADI*` immediate as a Fixnum unconditionally: `LOADI32` executes
  `SET_INT_VALUE` (heap `RInteger` past `FIXABLE`), unlike every other
  load-immediate form's `SET_FIXNUM_VALUE`, so literals past the
  narrowest shipped Fixnum range (-1073741824..1073741823, the 32-bit
  cross targets) now correctly refuse the proof instead of emitting a
  bare unchecked `mrb_fixnum()`. Latent only -- the program's own
  largest literals are +-9999999 -- so the regenerated
  `docs/bc2cpp_coverage.txt` is byte-identical.
