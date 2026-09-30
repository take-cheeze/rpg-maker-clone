- **bc2cpp** inlines `Integer#step`/`#upto`/`#downto` loops again when a bound is
  an Integer computed by arithmetic (`n.upto(n + 2)`), which ADR 0279 had sent back to
  the block call: the loop sits behind one per-loop `mrb_fixnum_p` test with the original
  call as the else branch, so a bignum bound still runs Integer's own body. Loops that may
  yield (resumable Fiber roots) keep the call. `Integer#upto` joins `downto`/`step` in the
  synchronous-block list so its unproven sites compile as block functions instead of
  `#error`. Checked against the interpreter at the Fixnum limits on a 64-bit and a
  32-bit-`mrb_int` build by `scripts/bc2cpp_step_inline_check.rb` (ADR 0287).
