- **Events:** Control Variables' actor Attack/Defence/Intelligence/Agility
  operand and the RPG2003 battle-monster Attack/Defence/Spirit/Agility
  operand now read the currently state-adjusted value, matching RPG_RT --
  previously both read the raw base stat, so a Weaken/Boost-type status had
  no effect on the value a Control Variables read reported.
