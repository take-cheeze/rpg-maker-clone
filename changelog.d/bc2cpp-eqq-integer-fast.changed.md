- Compiled `===` on an Integer receiver (every `when CONST` arm of a command
  switch such as `Game::Interpreter#execute`) compares two Integers natively.
  It used to go through `mrb_equal`, which for non-identical Integers still ran a
  full `funcall("==")` because `Integer#==` is not the basic identity method:
  ~5,500 executed funcalls in 40s of the RPG2k map scene, nearly all of the
  steady-state dynamic dispatch. Emitted only when no Ruby-defined `Integer#==`
  exists in the closed world; other argument types still use `mrb_equal`. New
  `scripts/bc2cpp_eqq_integer_check.rb` compares the emitted switch with
  `mrb_equal` on a real mruby core.
