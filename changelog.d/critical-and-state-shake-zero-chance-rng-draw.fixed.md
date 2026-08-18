- **RPG2000/2003 battles:** A critical-hit roll and a physical hit's status
  shake-off roll now always draw from the RNG, even when the computed chance
  is exactly 0 — matching RPG_RT's own `Rand::PercentChance`/`Rand::ChanceOf`,
  which roll unconditionally. Previously both rolls were skipped outright at
  a 0% chance (the common case for any battler with no crit ability at all),
  silently desyncing this build's shared RNG stream from a genuine seeded
  RPG_RT replay by one draw from that point on for the rest of the run. The
  roll's own outcome (never crit / never shake off at 0%) is unchanged —
  only whether the draw itself happens. Covered by two new
  `scripts/rpg2k_logic_check.rb` checks.
