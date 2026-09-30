- **bc2cpp** an ivar that an attr_writer, a computed-name setter, an
  `instance_variable_set` or a foreign source can write with a value
  the compiler did not type keeps a boxed slot instead of a typed `mrb_int`
  one, so those writes store the value like the interpreter instead of raising
  TypeError. New `scripts/bc2cpp_foreign_ivar_write_check.rb`. See
  `docs/adr/0279-bc2cpp-overflow-exact-fixnum-tier.md`.
