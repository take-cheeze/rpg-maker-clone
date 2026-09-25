- **bc2cpp** now compiles the remaining LCF schema and field-index loops
  directly on flash builds, removing the last two hot-only cfunc/RProc
  fallbacks. A same-flags Wio-style object comparison measures 208 bytes less
  `.text` and 2,904 bytes less total LCF object size while preserving schema
  order, key lookup, and memoization.
