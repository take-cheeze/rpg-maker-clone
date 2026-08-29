- **The Equip menu's candidate stat-comparison arrow now accounts for a
  two-handed weapon's forced-unequip side effect on the other hand, instead
  of only diffing the two items landing in the browsed slot.** Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine: equipping (or already wielding) a
  two-handed weapon forces the paired weapon/shield slot empty, and the
  stat preview must include that slot's own loss. The preview previously
  computed a different formula than what actually happens when the item is
  equipped, sometimes showing an Up arrow for a swap that is a net stat
  loss once the forced-off item is accounted for.
