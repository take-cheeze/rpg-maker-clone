- **bc2cpp's constant-interval proof (ADR 0318) now also vouches for operands
  of arithmetic, comparisons and exact-Array indexes** (docs/adr/0326): `HEAD +
  1`, `HEAD * 3 + COLS - 2` and `a[HEAD - 22]` with interval-bounded constants
  lose their tag test, slow-helper call and `[]` send (wio closed world:
  -42 `bc2cpp_send`, -17 `bc2cpp_slow_*` callers, -153 `mrb_fixnum_p` tests).
  `BC2CPP_NUMERIC_INTERVALS=0` restores the previous output byte for byte.
