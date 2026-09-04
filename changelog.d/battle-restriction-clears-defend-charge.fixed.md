- **A newly-inflicted forced-action state (sleep/paralysis, berserk, or
  confusion) now drops a battler's Defend stance and charged-attack flag
  immediately, even when the hit isn't lethal.** `Game::Battle#inflict_state`
  only cleared `defending`/`charged` through `#apply_knockout_reset`, which is
  gated on death, so a living ally or enemy that was Defending (or charging a
  held attack) when it got put to sleep, berserked, or confused kept the
  stale flag — wrongly halving incoming damage, or wrongly doubling its own
  next attack, until something else happened to clear it. Ported from a
  reference implementation's own `AddState` (NOT independently confirmed
  against genuine RPG_RT under wine): it resets both fields unconditionally
  whenever the post-add significant restriction (`#battler_restriction`) is
  non-normal, not only on death. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the pre-fix
  code.
