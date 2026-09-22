- **bc2cpp** extends `ClassLayout`'s ivar-class-hint analysis to resolve
  through a bare self-call (`@x = some_method(...)`) to a MONO, whole-
  program-provably-single-class method, the object-reference analogue of
  the existing `ARRAY_RETURN_PROOF` mechanism (same admission rule, same
  two-level stratification). Closes 5 real `CLASS_HINT`s
  (`RPG2k::Scene::StatusMenu`'s window ivars, via the shared `new_window`
  helper). Verified via a full before/after diff (zero regressions, zero
  new `#error`), all 22 static checks, and a real linked
  `RPGMAKER_BC2CPP=1` build. See ADR 0194.
