- **Show/Move/Erase Picture now no-op while a message window or choice list
  is open**, matching yado.tk's stated unconditional RPG_RT limitation. This
  was reachable in practice: `Scene::Map#step_parallels` (the earlier
  "parallel processes were paused too broadly" fix) already keeps a parallel
  process advancing during a message window opened by the foreground or by
  another interpreter, and its picture commands used to apply immediately
  regardless. `Game::Interpreter#do_show_picture`/`#do_move_picture`/
  `#do_erase_picture` now check a new `Scene::Map#message_window_open?` hook
  (queried through the existing `map_info` mechanism, same pattern as
  `#event_position`/`#character_screen_position`) and no-op when it answers
  true; a headless interpreter (no `map_info`, or a battle page) is
  unaffected. The picture's *other* non-picture commands in the same
  parallel process still keep running, unchanged.
