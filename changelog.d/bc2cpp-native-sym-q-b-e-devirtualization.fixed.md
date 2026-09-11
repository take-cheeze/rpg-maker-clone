- Fixed a real, live correctness bug in the opt-in (`RPGMAKER_BC2CPP=1`)
  AOT compiler's own whole-program devirtualization registry:
  `extract_native_method_names` recognized mruby core's `MRB_SYM`/
  `MRB_OPSYM` macros but not its `MRB_SYM_Q`/`MRB_SYM_B`/`MRB_SYM_E`
  siblings (`"name?"`/`"name!"`/`"name="`), leaving ~75 real native
  methods (`Array#empty?`, `Kernel#nil?`/`#frozen?`, `Numeric#zero?`,
  `Hash#key?`, `String#chomp!`, and more) invisible to the registry.
  This let a compiled call site wrongly assume a colliding name
  belonged only to a bytecode-defined method and devirtualize straight
  into it -- caught concretely as `Game::MoveRoute#empty?` getting
  devirtualized into calling itself, real infinite recursion. The same
  collision against any other class's own same-named native method
  would have compiled clean and silently misresolved instead, with no
  compiler warning. Fixed at the root in `extract_native_method_names`
  itself; confirmed the fix leaves every already-shipped class's own
  generated code byte-for-byte unchanged.
