- **bc2cpp** `BC2CPP_ENUM_STEP=1` (off by default) also takes the step form for
  `Range#each`: an Integer range runs a compiled step per element under a
  fiber, and every other range keeps mruby's own body. Covered by
  `scripts/bc2cpp/enum_step_range_check.rb`; see `docs/bc2cpp-enum-step.md`.
