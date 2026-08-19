- **RPG2003 cursed armor:** Equipping a cursed armor no longer inflicts one of
  its forced states if that state's database Persistence is left at "Ends"
  (the schema default) -- matching RPG_RT, which only lets *unequip*-triggered
  cures bypass the normal persistence check, not *equip*-triggered inflictions.
  Ordinary infliction (skills, attacks) is unaffected. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
