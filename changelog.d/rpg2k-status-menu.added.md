- RPG Maker 2000 main menu: the **Status** command now opens a working status
  screen (`Scene::StatusMenu`) instead of reporting "not implemented". It shows
  one party member's full detail — name and title, level, current EXP and the EXP
  still needed for the next level, HP/MP, the six stats (attack / defence /
  spirit / agility plus max HP/MP) and the five equipped items; LEFT/RIGHT cycle
  through the party. The read-only screen adds one piece of tested logic,
  `Game::Actor#next_level_exp` / `exp_to_next` (derived from the existing RPG2000
  EXP curve, nil at the maximum level), covered by two new checks in
  `scripts/rpg2k_logic_check.rb`; the rest reads existing accessors. With Item,
  Equip and Status done, only the Skill screen remains — it shares the battle
  effect formula and is best built with the battle system.
