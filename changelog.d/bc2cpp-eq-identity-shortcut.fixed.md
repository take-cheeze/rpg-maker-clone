- bc2cpp preserves mruby's object-equality shortcut before dynamically
  dispatching `==` for non-Fixnum `EQ` opcode operands, avoiding a Ruby method
  call when the values already compare equal and matching interpreter behavior
  for identity even when `==` is overridden.
