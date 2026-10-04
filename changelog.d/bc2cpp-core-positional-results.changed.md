- **bc2cpp** proves core Ruby collection results with fixed positional arguments,
  retaining Array and Hash memo classes through `each_with_object` and Array
  results through `drop`. Arity, block exits, overrides and argument-cache
  isolation are covered by generated, mutation and runtime checks.
