- **`--rgss_host_menu_test` opens a game's own menu.** Once the game is on its
  own map — and done walking, when `--rgss_host_move_test` is on too — the host
  presses cancel through the same input buffer a keyboard feeds and reports where
  the game went as `[RPGXP-HOST-MENU] scene=.. opened=.. frame=..`, read from the
  game's own `$scene`. That is the rung above walking: a menu is the first thing
  a game draws out of its *own* `Window_Base` subclasses, its own windowskin, its
  own font and its own `Bitmap#draw_text`, none of which a map scene touches.
  `scripts/rpgxp_boot_check.bash` asserts it on the editor test bed (stock
  scripts, menu enabled) in the same pass as the walk, and logs it for a released
  game, which opens on a cutscene where a menu that does not open says nothing.
