- **A wipe-triggering command run from a Common Event's Parallel Process now
  reaches the Game Over screen, instead of the wait being silently discarded.**
  `Game::Interpreter#check_game_over` raises the same `:game_over` wait
  whichever interpreter calls it — foreground or a Parallel Process's own —
  but `Scene::Map#drive_parallel_wait` had no case for it, so the request fell
  into the generic "background: ignore message/choice/teleport requests"
  branch and was immediately `#resume`d, leaving a fully-dead party free to
  keep wandering the map with no Game Over ever shown. Fixed with a
  `:game_over` branch that calls `#perform_game_over`, now generalized (like
  the earlier Show Battle Animation fix) to take the requesting interpreter
  explicitly rather than always stopping the foreground one. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the pre-fix
  code.
