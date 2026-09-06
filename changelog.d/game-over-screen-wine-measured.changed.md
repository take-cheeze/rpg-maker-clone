- The **Game Over screen** is now measured against a genuine `RPG_RT.exe`
  under wine on the route a player actually takes to it — a real party wipe in
  a "game over" battle — rather than only the injected Game Over event command.
  Confirmed and pinned by new `scripts/rpg2k_scene_check.rb` checks: the
  `GameOver/<name>` picture is drawn at the screen origin at its native size
  (an undersized probe picture proved RPG_RT neither stretches nor centres it)
  with palette index 0 opaque, the database's `gameover_music` starts as the
  screen comes up, no sound effect plays on entry or dismissal, the screen
  never times out, and Decision and Cancel are the only two buttons that
  dismiss it. No behaviour changed — real RPG_RT already did all of this the
  way this build does. Its screen-entry/exit fade (~1.6-1.7 s, about three
  times an ordinary scene transition's) is recorded in `docs/TODO.md` as still
  unmodelled, and the RPG2003-only Order screen is documented as still
  unmeasurable here: the one genuine RPG2003 `RPG_RT.exe` available renders
  nothing under this container's wine.
