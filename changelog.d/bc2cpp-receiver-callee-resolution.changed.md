- **bc2cpp** resolves 76 more dynamic dispatch sites to direct calls under the
  closed world (467 -> 391): implicit-self calls in module singleton methods,
  calls without keywords to keyword methods, constant-object calls to
  `module_function` copies that use blocks or `self`, and singleton
  `attr_accessor` reads and writes. Adds `scripts/bc2cpp_receiver_typing_check.rb`
  and ADR 0258.
