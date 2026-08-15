- **A skill/spell attack now rolls its own critical hit**, instead of never
  critting at all. Confirmed against EasyRPG Player's source: a skill rolls
  the caster's ordinary weapon-inclusive crit rate, the same rate a basic
  attack already uses, and triples the damage the same way — every offensive
  skill's damage was previously capped at its non-critical value on every
  single cast, in every fight.
- **A basic attack's critical/charge damage multiplier now applies before
  variance is rolled, instead of after.** Since variance spreads
  proportionally to its input, applying it before the multiplier and
  tripling the *result* afterward could only ever land on a multiple of 3 (or
  2, for a charged hit) away from the base — a narrower, wrong-shaped spread
  than rolling variance against the actual landed damage.
