- Add the RPG2003 front/back **row** battle mechanic (ADR 0053, Phase 1):
  `Game::Battle::Combatant` carries a `row` (front by default; RPG2000 never
  sets it), and a back-row defender is now harder to hit — a fixed 50%
  reduction applied to the attacker's hit rate through `Battle#to_hit` (basic
  attack) and `Party#skill_to_hit` (the 2003 physical-skill branch). The
  attacker-side back-row reach penalty and per-battler row derivation from the
  Battle Commands placement table are left as follow-up steps; the row
  multiplier is flagged TODO against the RPG_RT 2003 specification.
