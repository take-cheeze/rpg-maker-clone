- **bc2cpp**: a declared core receiver with no core subclass, such as `Array`, `Hash` or `String`, is typed again
  (`Array#size` is `Integer`) when the program does not subclass it, or subclasses it without overriding the method,
  and does not define the method on the core class itself. A program subclass that overrides the method, or a
  redefinition, keeps the send untyped. This restores the typed results lost by the explicit-receiver contract
  change, and the same rule also types implicit-self sends in a core leaf's own methods. Checks:
  `scripts/bc2cpp/explicit_receiver_override_contracts_check.rb`.
