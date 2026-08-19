- **RPG2003 battles:** An enemy that chooses its own AI "Escape" basic
  action now plays the same system escape sound the party hears on a
  successful Escape command, matching RPG_RT. Previously the monster
  correctly fled the fight, but no sound played at all. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
