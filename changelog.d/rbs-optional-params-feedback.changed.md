- **bc2cpp** type check: an optional parameter now takes its type from the call sites when every reaching call
  passes it. The candidate RBS (`--emit-rbs`, `--emit-rbs-suggestions`) writes `?T` instead of `?untyped`, and the
  IR feedback uses the type as an argument fact. A parameter that some call omits, and rest, keyword and block
  parameters, stay `untyped`. `BC2CPP_IR_ARGUMENT_TYPES=0` restores the old output. Covered by
  `scripts/bc2cpp/ir_argument_types_check.rb`; see `docs/bc2cpp-ir-feedback.md#optional-parameters`.
