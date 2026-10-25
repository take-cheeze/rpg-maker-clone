- **bc2cpp** dataflow queries hand out shared frozen cache entries on
  read-only paths: ~60 `reaching_definitions` call sites audited and
  switched to `shared: true` (the `BC2CPP_IR_SHARED_DEFINITIONS` path
  that already existed). Callers that need refusal diagnostics keep
  recomputing. Engine `type_check` output is byte-identical.
