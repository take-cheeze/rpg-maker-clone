- **bc2cpp** type check: rest, required keyword and block parameters now take their type from the call sites when
  every reaching call supplies them. The candidate RBS (`--emit-rbs`) writes `*T` for a rest parameter, `k: T` for a
  required keyword and a required block `{ }` when every call passes a literal block. A call that passes keywords to
  a rest parameter, omits a required keyword or passes a non-literal block keeps the parameter `untyped`, as do
  optional keywords. `BC2CPP_IR_ARGUMENT_TYPES=0` restores the old output. Covered by
  `scripts/bc2cpp/ir_argument_types_check.rb`; see `docs/bc2cpp-ir-feedback.md#rest-keyword-and-block-parameters`.
