- **Game Over screen:** Only the Decision key now dismisses the Game Over
  screen and returns to the title, matching real RPG_RT — Cancel used to work
  too, but EasyRPG's own `Scene_Gameover::vUpdate` checks only
  `Input::IsTriggered(Input::DECISION)`, with no reference to Cancel
  anywhere. Covered by a new `scripts/rpg2k_scene_check.rb` check.
