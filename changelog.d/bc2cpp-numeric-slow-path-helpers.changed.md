- bc2cpp: the else arm of the guarded numeric fast paths (`+ - * / % & | ^ << >>
  < <= > >= -@ zero? round`, 3,409 sites in the wio build) is no longer a by-name
  `bc2cpp_send` per site but a call to one typed helper per operator
  (`bc2cpp_slow_add`, `_lt`, `_div`, ...). The helper switches on the operand tags
  and runs mruby's own numeric/bigint C function (`mrb_num_add`, `mrb_cmp`,
  `mrb_bint_div`, `mrb_bint_lshift`, ...) for a bigint, heap Integer or Float
  operand, and dispatches by name only for the operand classes it does not own.
  A Ruby redefinition of the operator, a build without mruby-bigint and the
  32-bit `mrb_int` targets are handled exactly as before; the helper releases
  its GC arena temporaries. Covered by the new
  `scripts/bc2cpp_numeric_slow_check.rb` (compiled vs interpreted over a
  Fixnum/bigint/Float/nil/String/user-class matrix on 64-bit, 32-bit-`mrb_int`
  and no-bigint builds); see docs/adr/0292.
