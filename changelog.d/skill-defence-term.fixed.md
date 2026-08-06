- **Armour no longer resists fire spells.** An enemy-scope skill's damage was
  `effect - target.def / 4`, a defence term invented here; RPG_RT blunts a skill
  with the **same two rates that built its effect** —
  `physical_rate * def / 40 + magical_rate * spi / 80` — so a physical skill is
  stopped by armour and a magical one by the target's spirit. The flat term only
  coincided with that for a purely physical skill at rate 10: **211 of
  Nepheshel's 276 enemy-scope skills and 112 of mtf-meido-action's 116** differ
  from it, and **222 across the two games are purely magical**, every one of them
  being blunted by a stat RPG_RT does not let them see. `ignore_defense` (防御無視,
  13 and 7 skills) is read at the same time and skips the whole subtraction,
  both halves. The `dmg < 1` floor is deliberately untouched — that is a separate
  divergence from RPG_RT's floor of 0. See ADR 0041.
