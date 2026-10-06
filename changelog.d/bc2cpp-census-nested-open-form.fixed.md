- **bc2cpp** the dynamic-site census no longer ends the masked by-name copy of a
  helper written twice at that copy's own `#ifdef ... #else`, so a by-name call
  inside it (`bc2cpp_slow_rshift`) is not counted as live or attributed to the
  helper before it.
