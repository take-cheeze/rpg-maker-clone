- bc2cpp now computes `-x`, `x.zero?` and `x.round` inline when the receiver is
  an Integer (INTEGER_UNARY). Any other receiver, and `-MRB_INT_MIN`, still
  uses the ordinary dispatch. Before, these calls went through `mrb_funcall`,
  and `-@`/`zero?` also ran the VM again for a Ruby method in libmruby. The
  change removes 102 dynamic-dispatch sites. On the RPG2000 map path it removes
  about 3.8 calls per frame (`Game::Screen#pan_offset`,
  `Game::Interpreter#call_stack_snapshot`). Covered by
  `scripts/bc2cpp_runtime_devirt_check.rb`; see docs/adr/0200.
