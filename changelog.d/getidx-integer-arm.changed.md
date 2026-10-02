- **bc2cpp**: the optcarrot probe now feeds its `Integer#[]` shim to the compiler, so `bc2cpp_getidx` gets an
  exact-class Integer arm and executed by-name dispatches fall 32.6% (7,818,761 to 5,266,040). New
  `scripts/bc2cpp_getidx_integer_arm_check.rb` (with mutants). See ADR 0305.
