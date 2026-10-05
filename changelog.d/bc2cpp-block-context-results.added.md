- **bc2cpp** can retain call-specific receiver results through methods containing
  blocks by joining nested nonlocal returns and read-only captures, including
  later parent stores, while refusing captured writes and reflective local writers.
