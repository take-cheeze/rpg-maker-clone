- **bc2cpp** pools the class of a method parameter over every call site, so a
  receiver that is such a parameter dispatches directly (unguarded when every
  site passes a fresh instance of one class, guarded otherwise), and an
  `alias` no longer hides calls from the entry-argument proofs. See ADR 0282.
