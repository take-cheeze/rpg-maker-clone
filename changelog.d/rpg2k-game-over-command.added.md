- **Game Over (12520).** The event command now ends the game: the interpreter
  raises a `:game_over` request and `Scene::Map` answers it by stopping the event
  and returning to the title screen (the same path a game-over battle defeat
  takes), so nothing after the command runs. RPG2000 shows a Game Over graphic
  before the title; that screen is native-renderer work still to come, so this
  routes straight to the title. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` (the command raises a `:game_over` request and
  the following command does not run) and `scripts/rpg2k_scene_check.rb` (the
  scene returns to the title and abandons the event).
