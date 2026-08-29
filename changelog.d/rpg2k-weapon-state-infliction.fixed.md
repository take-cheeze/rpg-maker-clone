- **A basic Attack now rolls its own weapon's state-infliction chance**,
  instead of doing nothing at all — only Skills and Items ever rolled state
  infliction before, so a "Poison Dagger"-style weapon (a real mechanic
  several of Nepheshel's actual weapons use) could never poison anything on
  a plain swing. Ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine: each state a weapon's
  `state_set` flags rolls against its own `state_chance`, scaled by the
  target's susceptibility, the same way a skill's own infliction already
  works. A dual-wielding actor's second weapon can flag a different state or
  a different chance for the same one; RPG2003's `reverse_state_effect` flag
  flips a weapon's own states from inflicting to curing them, but only on
  RPG2003 — the same flag has no effect here on an RPG2000 database.
