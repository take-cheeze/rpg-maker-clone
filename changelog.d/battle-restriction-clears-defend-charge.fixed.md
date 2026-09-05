- **A newly-inflicted forced-action state (sleep/paralysis, berserk, or
  confusion) now drops a battler's Defend stance and charged-attack flag
  immediately, even when the hit isn't lethal.** `Game::Battle#inflict_state`
  only cleared `defending`/`charged` through `#apply_knockout_reset`, which is
  gated on death, so a living ally or enemy that was Defending (or charging a
  held attack) when it got put to sleep, berserked, or confused kept the
  stale flag — wrongly halving incoming damage, or wrongly doubling its own
  next attack, until something else happened to clear it. Ported from a
  reference implementation's own `AddState`, and confirmed against genuine
  RPG_RT.exe under wine: a Defending, `strong_defence` leader took a
  quarter-damage hit (21) when nothing interrupted the Defend, but the same
  attack against the same leader landed for full, undefended damage (116)
  once a Berserk-inflicting skill hit mid-round. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the pre-fix
  code.
