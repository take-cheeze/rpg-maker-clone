- The **RPG2000 Game Over screen**. `Scene::GameOver` fills the screen with the
  database's `GameOver/<name>` picture over its game-over music and returns to
  the title on a button press. Both routes RPG_RT reaches it by now go through
  it — the **Game Over** event command (12420) and a battle defeat whose
  encounter says "game over" rather than running a `[Defeat]` handler — where
  each used to drop straight back to the title with the run's ending unshown.
  A button still held from the fight that caused the defeat cannot skip the
  screen; it waits for a fresh press. A game that names no picture (or whose
  file is missing) still reaches the screen, on plain black, with the failure
  logged rather than the defeat itself failing.
