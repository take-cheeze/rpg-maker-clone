- **bc2cpp** now inlines a one-level `times` block that forwards the
  enclosing method's `yield`, removing the `LCF::Array2D#each` cfunc/RProc
  fallback from hot-only output while preserving control-flow and error
  behavior.
