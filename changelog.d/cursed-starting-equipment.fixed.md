- **RPG2003 actors:** An actor whose *starting* shield/armor/helmet/
  accessory is flagged "cursed" (forces a status condition while worn) now
  begins the game already afflicted, matching RPG_RT. Previously the
  forced state only applied once the item was equipped through the equip
  menu or a Change Equipment command — starting gear carrying the flag had
  no effect until manually unequipped and re-equipped. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
