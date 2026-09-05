- **Battle:** the critical-hit message line (「会心の一撃！！」 / 「痛恨の一撃！！」)
  is now keyed on which side *dealt* the crit, not which side took it,
  reverting an earlier revision's target-based reading. Confirmed under wine:
  swapping the database's own `actor_critical`/`enemy_critical` terms for
  distinct ASCII markers and forcing a guaranteed critical hit in both
  directions showed an ally's own critical hit against an enemy displaying
  the `actor_critical` marker, and a separate enemy's critical hit against
  that same ally displaying the `enemy_critical` marker — the "obvious from
  the words themselves" reading the earlier revision had talked itself out
  of. `actor_damaged`/`enemy_damaged` are genuinely target-keyed and
  unaffected; only the critical-hit line itself was wrong.
