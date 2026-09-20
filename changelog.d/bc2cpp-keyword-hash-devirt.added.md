- **bc2cpp** devirtualizes keyword calls that arrive as a trailing-Hash
  positional (KEYWORD_HASH_DEVIRT_SUPPORT). Once the keyword pairs are
  packed into `bc2cpp_kwh`, the call is an ordinary positional send, so the
  existing MONO resolution and POLY_SMALL_N runtime-class chain now apply
  with the Hash as the final argument. 8 real call sites convert (7 MONO,
  1 POLY chain for `:load_h`); the whole-program diagnostic is otherwise
  byte-identical with and without the change.
