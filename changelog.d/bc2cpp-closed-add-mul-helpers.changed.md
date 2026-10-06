- **bc2cpp** `bc2cpp_slow_add_f` and `bc2cpp_slow_mul_f` no longer dispatch by name when the
  closed world proves only Integer, Float, Array and String answer `+` / `*`
  (and mruby-time is not linked): String and Array receivers run a C++ mirror of
  `mrb_str_plus_m`, `mrb_str_times`, `mrb_ary_plus` and `mrb_ary_times`, any other
  receiver raises the proven NoMethodError, removing 1,154 generated sites from
  the by-name census. The by-name helper stays for builds that link Complex or
  Rational and under `BC2CPP_NUMERIC_SLOW_CLOSED=0`; `scripts/bc2cpp_numeric_slow_check.rb`
  compares the helpers with the real methods on 64-bit, 32-bit and no-bigint
  mruby (ADR 0361).
