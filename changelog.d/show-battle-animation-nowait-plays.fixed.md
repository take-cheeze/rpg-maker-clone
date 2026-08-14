- **A map-triggered Show Battle Animation (11210) with its "wait until it
  finishes" flag *off* now actually plays**, instead of being recorded and
  then silently never rendered. EasyRPG Player's own `Game_Interpreter_Map::
  CommandShowBattleAnimation` (`src/game_interpreter_map.cpp`) always starts
  the animation regardless of the wait flag — the flag only gates whether the
  interpreter pauses for it — but `Game::Interpreter#do_show_battle_animation`
  only entered an `:animation` wait when the flag was set, and
  `Scene::Map#drive_map_animation` (the only place anything ever read
  `battle_animation` off an interpreter) is reachable exclusively through that
  wait's own dispatch, so a fire-and-forget request had nothing left to pick
  it up. Fixed with a new `@battle_animation_pending` flag plus a destructive
  `#take_battle_animation_request` reader, polled by a new `Scene::
  Map#apply_battle_animation_request` from `#apply_interpreter_requests` —
  already run for both the foreground interpreter and every parallel process
  — which starts the shared animation slot with no owner when it is free (or
  drops the request when it is already busy, matching this build's existing
  "waits its turn" precedent for the waited-for collision case). A second new
  method, `#step_ownerless_map_animation`, is now polled unconditionally every
  real frame from `#update`, since nothing else was ever advancing an owner-
  less animation frame-by-frame — it is carefully scoped off an in-progress
  battle-round animation (`#drive_battle_animate`'s own job) to avoid double-
  stepping it. Covered by a new `scripts/rpg2k_scene_check.rb` check (a
  no-wait Show Battle Animation both lets the very next command run
  immediately and still plays the sprite/flash through to completion),
  confirmed to fail against the pre-fix code before the fix.
