- bc2cpp now devirtualizes one-argument `Array#push` calls through a guarded
  native append, preserving dynamic dispatch for subclasses, overrides,
  non-Arrays and other `push` arities. The regression check also covers the
  existing `Array#<<` fast path.
