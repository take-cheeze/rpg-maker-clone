- RPG Maker 2000: **basic attacks can now land critical hits** (3x damage). Each
  battler carries a 1-in-N critical chance read from the database — an actor's
  `has_critical_rate` / `critical_rate` (default 1/30), an enemy's `critical_hit`
  / `critical_hit_chance` — surfaced as `Game::Actor#crit_denominator` /
  `Game::Enemy#crit_denominator` and snapshotted onto the `Combatant`. When the
  fight has criticals enabled (an opt-in `Game::Battle` flag the live game turns
  on; off by default so seeded / headless fights stay reproducible), `deal_attack`
  rolls the attacker's chance and triples the damage on a hit, tagging the log
  entry `critical: true`. No critical lands on a same-side hit (a confused ally
  striking an ally), matching EasyRPG. Covered by new `scripts/rpg2k_logic_check.rb`
  checks (a 1-in-1 attacker always crits for 3x with criticals on; no crit when
  the flag is off or the attacker's denominator is 0). Elemental attributes and
  `prevent_critical` gear remain follow-ups.
