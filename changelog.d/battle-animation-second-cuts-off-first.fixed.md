- **A second Show Battle Animation (11210) now forcibly cuts the first one's
  sprite off**, instead of quietly waiting its turn for the shared on-screen
  slot to free up. Settled against EasyRPG Player's actual C++ source:
  `Game_Screen::ShowBattleAnimation` (`src/game_screen.cpp`) is a bare
  `animation.reset(new BattleAnimationMap(...))` — an unconditional
  `unique_ptr` replace with no check for whether the previous animation had
  finished. `Scene::Map#drive_map_animation` (`mruby-rpg2k/mrblib/
  scene/map.rb`) used to only claim the shared `@map_animation`/`@anim_wait`
  slot when it was free, and otherwise just returned early every frame for
  any interpreter that was not the current owner — a second request sat
  completely inert until the first happened to finish naturally, the
  opposite of "forcibly cuts off." Fixed by claiming the slot unconditionally
  for whichever interpreter's request is being driven this frame: if a
  *different* interpreter currently holds it, that request is torn down and
  immediately resumed (its animation no longer exists, so there is nothing
  left for it to keep waiting on), before the new request takes the slot
  over the same frame. `#draw_map_animation` needed no change — it already
  re-derives the animation sprite's visibility fresh from `@map_animation`
  every render, so a cut-off animation's last frame does not linger even for
  one frame. Not reproduced: EasyRPG's own decoupled, precomputed-duration
  wait (`Game_Interpreter_Map::CommandShowBattleAnimation` arms
  `_state.wait_time` up front, independent of the shared animation object's
  own lifecycle), which would let a cut-off interpreter's original countdown
  keep ticking rather than resuming instantly — a larger change than the
  observable cut-off behaviour this closes. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (two Common Event Parallel Processes,
  the first parked on a long fallback-wait animation and the second issuing
  its own drawable one a few frames later: the shared slot switches over well
  before the first's own duration could have finished it naturally, and the
  first interpreter resumes instead of hanging forever on a slot it no
  longer owns), confirmed to fail against the pre-fix code.
