- **`--rgss_host_move_test` walks the party in a game's own engine.** Once the
  game's own map scene is up it holds each direction in turn — through the same
  input buffer a keyboard feeds — and logs
  `[RPGXP-HOST-MOVE] start=.. end=.. moved=..`, read from the game's own
  `$game_player`. `scripts/rpgxp_boot_check.bash` asserts it on the editor test
  bed, whose start map is plain and walkable: a game whose own `Game_Player` reads
  `Input.dir4` and steps across its own passability is being *played*, not just
  drawn. A released game opens on a cutscene, so its walk is logged and not
  asserted.
