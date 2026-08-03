- MV movement smoke check: a new `--mv_move_test` flag drives the committed MV
  sample past New Game onto the map, then holds a direction (cycling
  down/right/up/left so an open direction is found on any map) and logs the
  player's start/end tile as `[MV-MOVE] ... moved=<bool>`. It exercises the full
  gameplay path — `RGSS::Input` → `MV#sync_input` → MV's `Input` → `Scene_Map` →
  `Game_Player` → `Game_Map` passability → position — so CI confirms input
  actually walks the player, not just that the map renders. Wired as a
  non-blocking `build` job step alongside the existing MV boot/battle smokes. The
  direction cycling (`MV.move_probe_dir`) is unit-tested in
  `mruby-mvjs/test/input_test.rb`.
