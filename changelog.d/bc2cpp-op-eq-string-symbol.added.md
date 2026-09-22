- bc2cpp derives `String#==` (`mrb_str_equal`) and `Symbol#==` (`mrb_obj_equal`)
  from mruby core C once class.c's BasicObject/Object/Module/Class are known
  owners, and emits them in `OP_EQ` after the identity and numeric arms, so a
  false String/Symbol comparison no longer dispatches through `mrb_funcall`.
  As a side effect of the same owner fix `Hash#include?` is now generated too.
