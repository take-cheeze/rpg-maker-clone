- **Memorize Location** (10820) and **Recall to Location** (10830) event
  commands are now handled. Memorize Location stores the player's current map
  id, x and y into three variables; Recall to Location teleports back to a
  position held in three variables — the counterpart pair used by RPG2000 games
  to save and restore a spot (e.g. a return-from-menu warp). Recall routes
  through the same teleport request the Teleport command raises, so the scene
  loads the map and moves the player. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
