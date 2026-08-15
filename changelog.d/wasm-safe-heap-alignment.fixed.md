- The browser build no longer aborts at startup with
  `RuntimeError: Aborted(alignment fault)`. Emscripten's `-sSAFE_HEAP=1` also
  checks access alignment, which quickjs trips as soon as it runs a script
  containing a nested function: a `JSFunctionBytecode`'s constant pool is
  allocated directly behind the struct, so on wasm32 the `JSValue` array starts
  4 bytes off its natural 8-byte alignment. The page now links with
  `-sSAFE_HEAP=2`, which keeps the out-of-bounds and null heap-access checks and
  drops only the alignment check — unaligned accesses are legal in wasm, and the
  build never goes through wasm2js.
