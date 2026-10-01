- **bc2cpp exact receivers reach every arm wrapper, and constants join the class pools (ADR 0301).**
  The exact-class proof of ADR 0280/0289/0296 (a literal, a register copy, a return class, an argument
  pool) was consumed only by the last send of `compile_send`; it now also drives the registered-expression
  chains (`size`, `empty?`, `first`, `keys` ...), the tail of a POLY chain and the `core_or_native`
  fallbacks, so a proven Array/Hash/String loses its class test and its by-name else. A constant whose
  every definition is visible (`LIST = [...].freeze`) has a class pool of its own, and `x.freeze` is `x`
  while Kernel#freeze is the only `freeze` an instance can reach; a `const_missing`, a Ruby `freeze` on
  instances or any outside definition of the name withdraws it. On the wio closed world the sites that
  can reach a by-name call drop from 9,839 to 9,663 (`bc2cpp_send` 3,294 to 3,138) with no new helper.
  Covered by `scripts/bc2cpp_exact_receiver_flow_check.rb` and
  `scripts/bc2cpp_exact_receiver_flow_mutation_check.rb`; `NOMETHOD_REVIEWED` is regenerated.
