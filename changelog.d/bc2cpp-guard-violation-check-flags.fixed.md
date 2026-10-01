- `scripts/bc2cpp_guard_violation_check.rb` appends its flags to the caller's
  `BC2CPP_CXXFLAGS` instead of replacing them, so it builds under a 32-bit
  `mrb_int` mruby.
