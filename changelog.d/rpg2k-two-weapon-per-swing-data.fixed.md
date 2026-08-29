- **A two-weapon actor's individual swings now each roll their own weapon's
  hit rate, elemental attributes, weapon states, and crit chance, instead of
  every swing reusing a value merged across both equipped weapons; and a
  basic Attack is no longer capped at two swings.** Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: each swing resolves to exactly one weapon —
  never a merge across both — and the swing-count cap doesn't exist in the
  original engine. A dual-wielding actor with two genuinely different
  weapons previously had every swing use the higher hit rate, the union of
  both weapons' elements, and either weapon's status-inflict chance,
  instead of each swing acting as that specific weapon's own attack; and an
  actor whose weapon combination totalled three or four swings only ever
  attacked twice.
