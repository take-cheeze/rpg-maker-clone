- **bc2cpp** reuses quoted immutable owner lists within a bounded generator-local
  cache and appends owner-call arguments directly, reducing temporary Array and
  String allocations while preserving generated C++ output.
