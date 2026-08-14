- **A waited-for Show Battle Animation (11210) now shows its sprite the same
  real frame the command runs, instead of one frame late.** Verified against
  EasyRPG Player's actual C++ source: `Game_Interpreter_Map::
  CommandShowBattleAnimation` (`src/game_interpreter_map.cpp`) always calls
  `Game_Screen::ShowBattleAnimation` in-line — building the animation —
  *before* it ever touches its own wait_time, so the sprite's frame-0
  content is visible the instant the command runs. `Game::Interpreter#
  do_show_battle_animation` only ever armed the `:animation` wait itself;
  `Scene::Map#drive_map_animation`, the one place anything actually built
  the animation, used to only ever be reached the *next* time `#drive_event`/
  `#step_parallel` found the interpreter already parked on that wait, so a
  waited-for play always missed its own first frame. Fixed by building the
  animation immediately once the interpreter is freshly parked on the wait
  (a new `#init_map_animation_this_frame`, factored out of
  `#drive_map_animation`), for both the foreground interpreter and a Common
  Event Parallel Process's own play — deliberately only the *build* moves
  up, not that first frame's own *advance*: `Game_Map::Update` calls
  `Game_Screen::Update` (the only thing that ever steps a just-built
  animation, screen/character-flash stomp included) *before*
  `UpdateForegroundEvents` each real frame but *after*
  `UpdateCommonEvents`/`UpdateMapEvents`, so a foreground-built animation
  gets no extra same-frame advance while a Parallel-Process-built one does.
  Closes the "structural one-frame startup latency" this codebase's own
  request/dispatch split was previously left with. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks, both confirmed to fail against the
  pre-fix code before the fix.
