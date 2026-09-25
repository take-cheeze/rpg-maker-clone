- **bc2cpp** now admits zero-argument `Range#each` blocks for the existing
  native counter-loop lowering, removing one hot-only LCF cfunc/RProc fallback
  and 237 generated source bytes.
