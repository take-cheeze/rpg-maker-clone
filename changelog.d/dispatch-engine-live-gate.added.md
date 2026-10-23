- **bc2cpp**: `StaticDispatchRegistrations.analyze(..., strict: true)` raises
  `EngineLiveError` instead of falling back to the receiver-blind cascade, and
  `scripts/bc2cpp/engine_live_check.rb` runs that strict analysis on the closed
  world with its canonical core gems. It fails today: an unknown-receiver `dup`
  in core `Enumerator#each` may create an engine instance. The gate is not wired
  into CI yet.
