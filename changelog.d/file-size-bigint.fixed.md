- `File#size` on a file larger than `mrb_int` (2 GiB on the 32-bit
  Emscripten, Wio and PSP builds) answered a `Float` -- and raised under
  `MRB_NO_FLOAT` -- where CRuby answers an `Integer`. Builds with mruby-bigint
  (every build in `build_config.rb`) now get a bignum from
  `mrb_bint_new_uint64` (the INT32 `mrb_bint_new_int64` leaves its mpz_t uninitialized); a build without bigint keeps the old Float arm. Ships
  as `patches/mruby-io-file-size-bigint.patch`, applied by
  `scripts/apply_mruby_patch.bash`, and the bc2cpp pin for mruby-io's `file.c`
  gained the patched file's hash.
