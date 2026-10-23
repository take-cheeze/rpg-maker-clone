- **bc2cpp** codegen passes read instructions through the bytecode IR helpers
  (`source_at`, `op?`, `each_source`) instead of indexing raw ireps. The
  generated C++ is byte-identical.
