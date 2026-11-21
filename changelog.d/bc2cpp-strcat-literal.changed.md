- **bc2cpp**: the literal pieces of string interpolation no longer allocate a
  String each; their bytes are appended to the result in place, and the
  result's String check is skipped where it is proven.
