- **bc2cpp** compiles all retained Fiber bodies and support drivers into native
  continuations, including nested iterators and Enumerator. Closed builds retain
  no instruction-byte arrays for these paths and reject bytecode execution inside Fibers.
