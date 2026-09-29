- bc2cpp now emits a guarded Float division fast path for `/` sends, retaining
  Ruby dispatch for other receiver types and Complex operands.
