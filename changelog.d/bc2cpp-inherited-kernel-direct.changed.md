- **bc2cpp** calls the Kernel and BasicObject natives an exact core receiver inherits (`nil?`, `class`, `dup`,
  `equal?`, `is_a?`, `kind_of?`, `frozen?`, `freeze`) directly, when nothing earlier in the receiver's lookup defines
  the name. `is_a?` and `kind_of?` are taken for a class or module argument; any other argument keeps the send.
