- **bc2cpp** symbol-read memo lookups avoid per-query tuple keys with an
  instruction-indexed outer table of register-keyed entries, preserving the
  1,024-query bound and memo-off behavior.
