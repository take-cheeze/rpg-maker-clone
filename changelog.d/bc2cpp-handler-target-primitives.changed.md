- **bc2cpp** builds exception target caches with direct integer arrays and small
  kind masks, avoiding temporary edge groups and per-kind Sets while preserving
  handler order and rescue/ensure semantics.
