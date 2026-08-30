- **Game Over screen:** Only the Decision key now dismisses the Game Over
  screen and returns to the title, matching real RPG_RT — Cancel used to work
  too, but a reference implementation's own game-over update logic (not
  independently confirmed against genuine RPG_RT under wine) checks only
  the Decision key, with no reference to Cancel
  anywhere. Covered by a new `scripts/rpg2k_scene_check.rb` check.
