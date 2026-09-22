- `LCF`'s 32-bit two's-complement helpers (`#read_ber`, `#write_ber`,
  `#unpack_int32`, `#pack_int32`) no longer spell `0xffff_ffff`/`0x8000_0000`/
  `0x1_0000_0000` as bare literals. mruby's own compiler bakes any literal
  wider than 32 bits into a bignum pool entry regardless of the eventual
  runtime's `mrb_int` width, and re-decodes that entry from its string form on
  every execution of the instruction — on this project's native (64-bit
  `mrb_int`) desktop build, `#read_ber` alone (called from `Array1D#[]` for
  every `:int`-typed chunk) measured over 100,000 such re-decodes in a 15
  second RPG2000 map-scene session. The three values are now `LCF::INT32_MASK`
  / `INT32_SIGN_BIT` / `INT32_WRAP`, computed once via small-literal
  `Integer#<<` shifts at module load instead, which eliminates the per-call
  cost entirely on this build (0 bignum constructions over the same 15 second
  session) while keeping the exact same bigint promotion the 32-bit cross
  targets (Emscripten, Wio, PSP) still correctly need. New tests cover
  `#unpack_int32`/`#pack_int32`'s signed-32-bit round trip and the constants'
  exact values.
