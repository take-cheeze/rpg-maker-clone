- **Change Main Menu Access** (11960) and **Change Save Access** (11930) event
  commands are now handled. Both are RPG2000 toggles stored on `Game::State`
  (and persisted in the save): while menu access is forbidden the map's cancel
  button no longer opens the main menu, and while save access is forbidden the
  menu's Save command reports that saving is disallowed instead of writing a
  save. Both default on, and a save written before the flags existed keeps them
  enabled. Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
