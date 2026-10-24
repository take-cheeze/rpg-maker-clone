- **bc2cpp**: constructor class pools now cover optional `initialize` positions
  whose defaults are all literals (CONSTRUCTOR_OPTIONALS). Each position joins
  only the `new` sites that pass it. On the closed world this adds 11 ivar
  class pools (`Game::Battle#@rng` is exactly `Game::Rng`, among others) and
  removes 98 runtime class tests from the generated C++, mostly in battle code.
  `BC2CPP_CTOR_OPTIONALS=0` restores the old rule; checked by
  `scripts/bc2cpp/constructor_optionals_check.rb`.
