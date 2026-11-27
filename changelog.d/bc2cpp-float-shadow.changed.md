- **bc2cpp** keeps a Float that only arithmetic and comparisons read as a plain
  C value instead of a heap object, so the EXP curve and screen tint math
  allocate about two thirds fewer Floats on 32-bit boards such as the Wio
  Terminal.
