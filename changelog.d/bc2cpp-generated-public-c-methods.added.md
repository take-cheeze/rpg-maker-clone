- bc2cpp now emits exact-class calls to mruby's public, frame-independent C
  method implementations for supported zero-argument core registrations,
  including Array mutation/read methods, Hash clear/read methods, and String
  symbol conversion.
