- **bc2cpp judges the whole-name gates against a proven receiver set** (ADR 0323).
  A `def`/`alias_method` directly inside `class << <constant>` lands on that
  object, so it no longer makes the name an unknown definer or an installed
  name for instances; a name that natives or outside Ruby also spell is
  resolved per class (the first definer on the class's lookup path is a Ruby
  definition); and a flow-proven exact Hash calls the compiled `Hash#delete`
  instead of a guard chain over user classes. 33 by-name sends of the wio
  engine gems are removed (`update` on `RPG2k::Window`/`Game::Interpreter`,
  `delete` on a Hash); `BC2CPP_NATIVE_CLASS_ARMS=0` turns it off.
  `BC2CPP_NATIVE_ARMS_REPORT=FILE` and `scripts/bc2cpp_native_arms_report.rb`
  measure what each lever would remove. Covered by
  `scripts/bc2cpp_native_class_arms_check.rb` and its mutation check.
