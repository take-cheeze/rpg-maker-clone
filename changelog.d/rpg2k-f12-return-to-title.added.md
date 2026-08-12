- **RPG2000/2003**: pressing **F12** now returns to the title screen from any
  scene (map, menu, Game Over, ...), matching `RPG_RT.exe`'s reset hotkey.
  Reuses the existing `return_to_title` teardown already used by the "End
  Game" menu command and the Game Over screen. `RGSS::Input::F12` is now
  defined for every maker's scripts to read as well.
