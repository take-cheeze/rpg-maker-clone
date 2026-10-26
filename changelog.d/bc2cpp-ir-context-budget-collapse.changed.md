- **bc2cpp** `ir_context_results_check.rb` runs 12 type-check variants instead of
  20: each context-budget matrix compares its base against one combined
  all-controls-off variant rather than five single-control ones. The old
  per-control matrix returns with `BC2CPP_CONTEXT_BUDGET_SPLIT=1` when the
  combined comparison needs attribution.
