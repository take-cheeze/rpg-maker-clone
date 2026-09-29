- **Typed embedded ivars** (`mrb_int`, `mrb_sym`, `mrb_bool`, Integer-or-nil) are
  visible to `instance_variable_get/set`, `instance_variables`, `inspect`,
  `Marshal` and `dup`: the RData ivar descriptor now lists them with a kind and
  the runtime boxes on read and type-checks on write. An ivar some path reads
  before `#initialize` assigns it stays a boxed slot, so an unset read is nil
  instead of 0 or false (ADR 0261, `scripts/bc2cpp_typed_reflection_check.rb`).
