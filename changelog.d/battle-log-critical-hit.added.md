- **The battle log announces a critical hit in the game's own words.**
  `actor_critical` / `enemy_critical` (「会心の一撃！！」 / 「痛恨の一撃！！」) were
  held back by ADR 0036 because which side keyed them was unclear from the two
  test beds' data alone. Reading EasyRPG's actual `GetCriticalHitMessage`
  settles it: the term is keyed on the **target** taking the crit, the same
  rule `actor_damaged` / `enemy_damaged` already follow, not the attacker's
  side the 会心 / 痛恨 wording suggests. `Game::States::BattleText.critical`
  returns the bare term — no battler name in front of it, unlike every other
  predicate here — and `battle_action_body` slots it between the start line
  and the damage line, matching where RPG_RT prints it. A blank term is
  all-or-nothing with the rest of the entry, falling back to the composed
  English's existing `' (critical!)'` suffix. See ADR 0036's addendum.
