- **Battle:** curing a state now resets its "turns held" counter, so a
  state cured and then reinflicted later in the same fight no longer
  inherits a stale duration and auto-releases too early -- matching RPG_RT,
  whose `State::Add`/`State::Remove` share one literal field for "present"
  and "turns held," so the two can never drift apart there.
