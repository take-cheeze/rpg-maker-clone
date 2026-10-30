- **bc2cpp** reuses content-checked Prism trees when folding class-body unit
  constants, avoiding repeated parses of the same file while preserving source
  rewrite detection and owner lookup behavior.
