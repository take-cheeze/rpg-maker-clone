- **bc2cpp `!=` on a bigint receiver is one shared helper call.** Every `!=` site
  used to carry a by-name `mrb_funcall` of `==` for bigints. They now call
  `bc2cpp_bigint_eq`, emitted once per file: it runs `Integer#==`'s own
  `mrb_bint_cmp` answer, or the send where a program reopens `Integer#==`
  (`scripts/bc2cpp/integer_fast_arms_check.rb`).
