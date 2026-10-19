- Group bc2cpp native registration and result-signature contracts into two
  host suites, preserving 68 assertions and sharing process setup. Schedule
  native arity, AST-return and format-conversion checks in CI, and run the new
  suites once through coverage instead of repeating checks in workflow steps.
