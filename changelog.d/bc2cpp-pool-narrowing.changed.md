- **bc2cpp** (ADR 0375 addendum): the class-pool fixpoint narrows on class tests, so an ivar or argument stored
  after `raise ... unless x.is_a?(C)` is proven `C` in every method that reads it.
