- **bc2cpp** `BytecodeIR` models `rescue`/`ensure` catch-handler edges (opt-in
  via `include_handlers:`) with reachability, dominance and every-path queries;
  the fixnum proof and rescue recognizer read their handler sets from it.
  Generated output is unchanged.
