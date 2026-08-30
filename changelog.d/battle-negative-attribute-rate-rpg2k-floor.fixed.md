- **A negative elemental attribute rate no longer turns a battle attack into
  a heal.** A database's `a_rate`..`e_rate` fields are plain signed ints with
  no validation, so a deliberately-negative rank rate (the old "elemental
  absorb" editor trick) is real, reachable data — not RPG2003-exclusive
  content, contrary to this codebase's own prior assumption.
  `Game::Battle#apply_attr_multiplier` applied a negative rate as a literal
  percentage multiplier exactly like a positive one, and neither of its two
  call sites (`#deal_attack`, `#apply_skill_hit`) floor the *result* at zero,
  so `target.hp -= dmg` applied the negative figure as a genuine heal — on
  every edition, the opposite of RPG2000's real "just don't scale it"
  behaviour. Ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine: its own attribute-multiplier
  code guards
  both the physical and magical bucket-max rate against an edition-gated
  limit (-1 on RPG2000, unbounded-negative on RPG2003): RPG2000 drops a side whose best rate is
  negative from consideration entirely, where RPG2003 lets a lone negative
  side scale damage directly and falls back to the *milder* of the two rates
  (not a multiply) once either side is negative and both are present. Ported
  with a new `Game::Battle` `rpg2003:` constructor flag (`Scene::Map
  #open_battle` passes `db.rpg2003?`) and an `#above_attr_limit?` helper.
