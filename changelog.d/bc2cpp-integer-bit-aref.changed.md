- **bc2cpp** reads `n[i]` on a Fixnum inline when the program's only
  `Integer#[]` is the bit read `(self >> i) & 1`, as in optcarrot's shim. It
  no longer goes through the generic index chain into the compiled body. This
  cuts optcarrot's startup by about 0.31G instructions (2.41G to 2.10G) and
  each frame by about 0.8M. See `docs/bc2cpp-integer-bit-aref.md`; the check
  is `scripts/bc2cpp/integer_bit_aref_check.rb`.
