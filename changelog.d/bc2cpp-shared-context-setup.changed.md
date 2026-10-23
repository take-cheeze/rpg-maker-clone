- **bc2cpp context CI checks** share guarded source/native setup across private,
  sequential inference forks. All switch and solver-budget comparisons and the
  independent CLI baseline remain; early variant-control reads fail the check.
