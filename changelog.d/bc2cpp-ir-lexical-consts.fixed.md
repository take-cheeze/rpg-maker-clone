- **bc2cpp** no longer reads one arm of a ternary as the constant a name refers to. `(c ? A : B)::X`, a superclass written
  `(c ? B : nil)` and `include(c ? A : B)` now follow every arm, and a name that the arms disagree on is left unresolved.
  The declared-constant `frozen` and bool-compare proofs likewise require every writer that reaches the read.
