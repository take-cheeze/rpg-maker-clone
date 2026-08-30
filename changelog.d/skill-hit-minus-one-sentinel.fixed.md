- **A skill with `hit` set to -1 (a RPG_RT sentinel meaning "use the
  caster's own weapon-based hit chance") no longer misses unconditionally.**
  The raw -1 was flowing straight into the roll comparison, which can never
  succeed against a 0..99 die; it now resolves to the caster's `hit_rate`,
  matching a reference implementation's own hit-chance formula here —
  ported, not independently confirmed against genuine RPG_RT under wine.
