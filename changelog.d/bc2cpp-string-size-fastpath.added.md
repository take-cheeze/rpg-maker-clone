- bc2cpp now devirtualizes exact base `String#size` calls in non-UTF-8 builds,
  while retaining Ruby dispatch for UTF-8 builds and runtime overrides.
