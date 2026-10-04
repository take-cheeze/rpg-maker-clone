- **bc2cpp** compiles a method reachable from a `Fiber.new` block whose own body
  cannot suspend, behind the same run-time hand-off `CORE_BLOCK_GUARD` uses for
  core methods (ADR 0333). `LCF::Array2D#each`, `Game::Actors#each` and
  `Game::Party#each` now compile, taking the whole program's `#error` markers from
  8 to 5. `BC2CPP_FIBER_BODY_GUARD=0` restores the blanket refusal.
