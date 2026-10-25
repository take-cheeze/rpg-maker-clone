- **bc2cpp**: audited core calls reuse proven Fixnum arguments to remove
  redundant Integer type tests and dispatch fallbacks. Partially proven
  `byteslice` calls retain only the unproven argument's check.
