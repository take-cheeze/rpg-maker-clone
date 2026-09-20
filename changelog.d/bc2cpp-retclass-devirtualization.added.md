- bc2cpp now uses exact-class return annotations when tracing typed call
  receivers, including user-defined `[]` methods emitted as `GETIDX` bytecode
  in ordinary and shifted block bodies.
