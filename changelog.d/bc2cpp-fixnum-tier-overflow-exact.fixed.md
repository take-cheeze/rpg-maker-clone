- **bc2cpp** the Fixnum tier of compiled `+ - *` (including `+= n`, `-= n` and
  the proven arms) no longer wraps: a result outside the C type or the Fixnum
  range is built by Integer's own body (`fact(25)` now equals the interpreter),
  `>>` with a negative count and Range#each at the top of the Fixnum range box
  through `FIXABLE`, and an arithmetic result is no longer treated as a proven
  Fixnum or a `mrb_int` field type. New `scripts/bc2cpp_fixnum_overflow_check.rb`
  compares compiled and interpreted answers on a 64-bit and a 32-bit `mrb_int`
  build. See `docs/adr/0279-bc2cpp-overflow-exact-fixnum-tier.md`.
