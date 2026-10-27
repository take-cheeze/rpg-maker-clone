- **bc2cpp compares and reduces Integers inline.** `a == b` checks for an
  Integer pair before the `mrb_obj_eq` call, and `x % 2**k` with a constant
  divisor becomes a bit mask. See `docs/bc2cpp-integer-fast-arms.md`; checked
  by `scripts/bc2cpp/integer_fast_arms_check.rb`.
