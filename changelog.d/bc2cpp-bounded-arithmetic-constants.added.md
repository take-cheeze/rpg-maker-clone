- bc2cpp now resolves constant assignments formed by bounded integer `+` and
  `-` bytecodes, allowing later constant reads to inline their exact values.
