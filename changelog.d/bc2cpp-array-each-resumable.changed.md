- The bc2cpp compiler (`tools/bc2cpp/codegen_method.rb`) now gives `Array#each`
  a resumable variant beside its fast body. Inside a Fiber, the guard calls the
  variant, which suspends through VM frames, instead of the saved bytecode or the
  per-owner enum-step driver. The variant is compiled without the program-wide
  receiver proofs, so a subclass that overrides `[]` or `length` still runs its
  own method. With `BC2CPP_ENUM_STEP=0` the output is unchanged.
  `scripts/bc2cpp/enum_step_array_check.rb` covers it.
