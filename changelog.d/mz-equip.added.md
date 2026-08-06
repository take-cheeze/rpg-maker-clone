- **MZ equips things, and the stat moves with them.** `--mz_equip_test`
  (`MZ_MODE=equip`) hands the party a weapon through a Change Weapons command,
  walks the party menu's cursor to Equip, confirms through the equip command and
  slot windows and puts the weapon on — asserting the actor's *attack* rose, not
  merely that the slot filled, since a slot can hold an object while
  `Game_Actor.paramPlus` never reaches the stat the rest of the engine reads.
  `Scene_Equip` was the last major scene nothing here entered: the test bed
  declared five equip types, a weapon type and an armor type while
  `Weapons.json` and `Armors.json` were empty, so no slot ever had anything to
  hold. It now authors a weapon and an armor, plus the armor-type trait the
  class was missing — `isEquipAtypeOk` is a plain trait lookup, so equipment
  whose type nobody allows is silently unselectable.
