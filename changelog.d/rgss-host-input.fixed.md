- **A game running its own engine can now be played.** An RGSS scene loop is
  `loop { Graphics.update; Input.update; update; … }`, and this engine drained
  the keyboard backends' buffered transitions inside `Graphics.update` — which
  the game's own `Input.update` then wiped (a trigger lives one frame) before the
  scene read it. `Input.trigger?` was permanently false under the RGSS script
  host: no New Game on a game's title screen, no message advance, no menu; only
  held state (`press?`, `dir4`) worked. The drain moved to `Input.update`, where
  RGSS says input refreshes — expire last frame's triggers, apply this frame's
  transitions, then the repeat bookkeeping. The built-in RPG2000/XP flows and the
  MV/MZ bridges call `Input.update` once a frame as well, so their timing is
  unchanged.
- **`--rgss_host_new_game`** taps the confirm key on a game's own title screen so
  a headless run gets into the game without a keyboard — the script-host twin of
  `--rpgxp_new_game`, which drives the *built-in* title instead — and the host
  logs each scene the game reaches as `[RPGXP-HOST-SCENE]`, read from the game's
  own `$scene`. `scripts/rpgxp_boot_check.bash` now requires both XP beds to
  reach a *second* scene, so "the game drew its title and sat there" fails the
  check.
