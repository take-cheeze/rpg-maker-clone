- **bc2cpp IR feedback** consumes independently proven ivar, constant and incoming
  argument types at register reads, retaining initialization and mutation checks
  and supporting additional inferred RBS return suggestions.
  The existing trace RBS signatures also gain 27 independently inferred return
  bounds, including nullable results.
