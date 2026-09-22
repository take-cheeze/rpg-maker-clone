- Compiled `GETCONST`/`GETMCNST` reading a bare name the whole program
  provably binds to one Fixnum value for the life of the VM inlines that
  literal outright, skipping the runtime lookup entirely (previously only a
  class/module-valued constant could be cached, and only after its first
  lookup -- an Integer constant is now free, from the very first read).
  `IntegerConstants.analyze_values` extends the existing Fixnum-kind proof
  (`IntegerConstants.analyze`) to the actual VALUE, admitting a name only when
  every one of its definitions -- literal or, transitively through aliases,
  another admitted name -- resolves to the identical number; two definitions
  disagreeing, or an alias cycle with no literal at its base, are refused.
  This is the RPG2k desktop build's dominant remaining constant-lookup cost:
  `case cmd.code when Cmd::SHOW_MESSAGE` compiles one `GETMCNST` per `when`
  arm, and `Game::Interpreter::Cmd` alone has ~130 members scanned in
  sequence on every command dispatch (measured: ~1160 `mrb_const_get` calls
  per frame from `Game::Interpreter#execute_impl` alone, gone entirely after
  this change). New `scripts/bc2cpp_integer_const_inline_check.rb`.
