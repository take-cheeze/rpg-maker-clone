- **Game over on a battle defeat.** An Enemy Encounter whose defeat mode is
  "game over" (rather than a custom `[Defeat]` handler) now ends the game when the
  party is wiped: the battle shows its defeat result, and dismissing it returns to
  the title screen instead of resuming the event — the rest of the event never
  runs. Encounters that define a `[Defeat]` handler still route it as before, and
  victory / escape are unchanged. `Scene::Map` reads the encounter's
  `defeat_game_over` flag (already parsed by the interpreter) to choose between the
  two paths. RPG2000 shows a Game Over graphic before the title; that screen is
  native-renderer work still to come, so this routes straight to the title — the
  faithful end state. Covered by a new check in `scripts/rpg2k_scene_check.rb` (a
  game-over defeat returns to the title and abandons the rest of the event).
