- Add the RPG2003 active-time (gauge) battle-timing model (ADR 0053, Phase 2
  foundation): `Game::Battle::Combatant` carries a `gauge` (0..`GAUGE_MAX`),
  and `Game::Battle` advances every living battler's gauge at an AGI-proportional
  rate via `advance_gauges` / exposes `ready_combatants` (full-gauge battlers,
  gauge-descending). The engine is a no-op unless `battle_type == 2`, so
  RPG2000 and the 2003 traditional presentation keep the turn-based machine
  untouched. The per-frame `Scene::Battle` turn-picker that actually drives
  turns off the gauge is deferred to Phase 3 (the 2003 boot path); the
  `GAUGE_MAX` / `GAUGE_AGI_RATE` fill curve is flagged TODO against the RPG_RT
  2003 specification.

  The database's battle-setup `battle_type` (Battle Setup chunk 0x1D field 7)
  is now plumbed into `Game::Battle` at construction via a `battle_type:`
  keyword (default 0); `Scene::Battle` passes `db.battlecommands.battle_type`
  (0 for every RPG2000 project, which has no Battle Commands table). This is
   the first Phase-3 (boot) slice: it selects the gauge engine for a 2003
   gauge battle the moment one is reached, without touching the turn-based
   path.

   The active-time turn cycle is modelled too: `Game::Battle#reset_gauge(c)`
   empties a combatant's gauge after it acts, and `Game::Battle#pop_ready`
   returns the highest-gauge ready combatant and resets it -- the fill ->
   ready -> act -> refill loop the per-frame `Scene::Battle` picker will drive
   in Phase 3. Both are nil / no-op for a turn-based battle.
