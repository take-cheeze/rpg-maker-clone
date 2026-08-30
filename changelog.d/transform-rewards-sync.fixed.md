- **A monster that Transforms mid-fight now pays out its new form's
  EXP/gold/item drop on defeat, not its original form's.** The battle math
  already repointed the combatant at the new monster; the troop's own
  reward bookkeeping (a separate object at the same slot) was never told,
  matching a reference implementation's single repointed database-row
  pointer instead of this engine's two independent objects — ported, not
  independently confirmed against genuine RPG_RT under wine.
