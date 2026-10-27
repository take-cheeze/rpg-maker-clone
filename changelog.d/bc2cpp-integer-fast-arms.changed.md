- **bc2cpp compares and reduces Integers inline.** `a == b` checks for an
  Integer pair before the `mrb_obj_eq` call. `a != b` compares two Integers
  directly when the closed world proves `Integer#==` is the native one.
  Before, a `!=` between two different Integers went through `mrb_funcall`.
  `x % 2**k` with a constant divisor becomes a bit mask. On the optcarrot
  probe this cuts per-frame instructions from 54.8M to 50.4M (−8%). See
  `docs/bc2cpp-integer-fast-arms.md`; checked by
  `scripts/bc2cpp/integer_fast_arms_check.rb`.
