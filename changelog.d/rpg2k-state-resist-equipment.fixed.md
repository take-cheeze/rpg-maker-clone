- **Defensive equipment (shield/armor/helmet/accessory) can now resist a
  status effect from landing at all**, on top of a target's existing A-E
  susceptibility rank. Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine: an item
  flagging a state in its own
  `state_set` reduces that state's chance to land by its `state_chance`
  percent, taking the single strongest piece of resistance worn rather than
  stacking every equipped item. This build parsed those fields but never
  read them defensively, so a "Poison resist" accessory or similar item had
  no effect on its wearer.
