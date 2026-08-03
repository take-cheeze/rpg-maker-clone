- The RPG2000 runtime can now **Continue from a real `Save<N>.lsd`**.
  `Game::State.from_lsd` rebuilds the game state (hero map/position/facing,
  party roster, gold, items, switches and variables) straight from a parsed
  `LcfSaveData`, and `continue_game` loads an editor save dropped into the game
  directory in preference to our Marshal save. Covered by a new
  `scripts/rpg2k_save_load_check.rb` integration check, verified against the real
  Nepheshel save (leader on map 12 at (21,23), 100G, two items). See ADR 0012.
