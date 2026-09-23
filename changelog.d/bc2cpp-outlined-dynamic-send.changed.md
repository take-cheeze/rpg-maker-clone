- **bc2cpp**: every dynamic call in generated code now goes through one
  out-of-line `bc2cpp_send` helper instead of a symbol lookup plus
  `mrb_funcall_id` at each call site. The RPG2k compiled gem is 3.9% smaller at
  `-Os` (the wio setting) and 2.7% smaller at `-O3`, with no behaviour change.
  See ADR 0209.
