- **`--rgss_host_save_test` opens a game's own save screen.** Called the way that
  game's own Save Screen event command calls it — `$game_temp.save_calling`,
  which its `Scene_Map#update` acts on — and reported as
  `[RPGXP-HOST-SAVE] scene=.. reached=.. frame=..`. This is the one rung that
  reads a *file* back: a game's `Window_SaveFile` stamps each slot from
  `File#mtime` and its `Scene_Save` seeds the newest-slot search with
  `Time.at(0)`, the code that made `mruby-time` necessary and that nothing had
  executed; its own `save_data` then writes a real file. `reached=` is answered
  from the scenes the game has *been through*, since a save screen hands control
  back to the map as soon as it has written.
- **The reserved CI display numbers are now a block.** The XP boot check takes
  112..119 and the RGSSAD A/B 120..121, so adding another probe pass does not
  renumber an unrelated check.
