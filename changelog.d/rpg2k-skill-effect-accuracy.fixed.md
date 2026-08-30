- **A Skill/Item's own HP/SP change and ATK/DEF/SPI/AGI stat modifiers now
  roll their own accuracy**, instead of applying unconditionally on every
  cast. Only state infliction ever consulted a skill's `hit` field — the
  actual damage, heal, or stat buff/debuff always landed regardless of the
  skill's own accuracy. Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine: each
  affected field rolls independently, so a compound skill can land its
  damage while an accompanying debuff misses, or the reverse. An item's
  effect is unaffected — real RPG_RT's medicine algorithm has no accuracy
  concept at all.
