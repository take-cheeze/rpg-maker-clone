- **bc2cpp** factory and fragment forward-use walks share one flat work-stack
  core instead of three hand-rolled pair-Array traversals, preserving walk
  order, escape conservatism, alias budgets and ordered results.
