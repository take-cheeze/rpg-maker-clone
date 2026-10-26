- **bc2cpp** join-dominance queries share the canonical opaque-register key
  snapshots instead of sorting and freezing a fresh key per query, preserving
  mutable-input, empty/nil and `BC2CPP_IR_QUERY_KEYS=0` behavior.
