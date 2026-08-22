- Fixed the headless probe harness (`--rgss_host_new_game`/`move_test`/
  `menu_test`/`battle_test`/`save_test`) being silently blind on every real
  RPG Maker VX Ace game. `RPGXP::ScriptHost` read `$scene` directly to see
  what scene a game was in -- correct for XP/VX (RGSS/RGSS2), but VX Ace
  (RGSS3) replaced that convention with `SceneManager`, and its stock
  scripts never assign `$scene` at all. Confirmed against a real downloaded
  VX Ace release's full 213-section bundle: zero `$scene =` assignments,
  every scene threaded through `SceneManager` instead. The game itself ran
  fine the whole time -- gdb caught it mid-`Tilemap#refresh` on a real map
  -- but every probe waiting on `$scene` silently never started, producing
  no crash and no scene-change log output at all, which read as an inert or
  hung run. Fixed with `ScriptHost.current_scene`, which falls back to
  `SceneManager.scene` when `$scene` is `nil`. The same release now reports
  `Scene_Title` at frame 1 and `Scene_Map` at frame 87. This affected every
  VX Ace game's headless testability, not any one release's playability.
