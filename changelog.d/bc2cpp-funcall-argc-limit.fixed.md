- **bc2cpp no longer emits a dynamic call with more than 16 variadic
  arguments.** A splat of a literal-sized array unrolls to one argument per
  element. Past 16, mruby's `mrb_funcall`/`mrb_funcall_id` raise "Too long
  arguments. (limit=16)". `Game::Battle.from_actor`'s 22-field
  `Combatant.new(*[...])` did exactly that, so the boot check's Nepheshel
  battle failed with it on the bc2cpp desktop build. That was hidden until
  the rescue live-in fix let the battle get that far; it now plays through
  to the result. Such a call now goes through `mrb_funcall_argv`, which has
  no cap. `scripts/bc2cpp_funcall_argc_check.rb`
  pins it.
