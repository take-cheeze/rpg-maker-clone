- **A Set Move Route command targeting a currently-hidden (appearance-
  conditions-unmet) map event now hard-freezes the interpreter, matching real
  RPG_RT**, instead of silently completing. A hidden event never gets a
  `Game::Character` built (`Scene::Map#build_events` skips it outright), and
  `#apply_move_request`'s target lookup used to just drop the request when it
  found nothing in `@events` — the same as a genuinely nonexistent event id.
  The target is now also checked against the map's raw event table
  (`@map.unit.events`): a real event with no page currently selected is
  recorded in a new `@stuck_move_targets` list that permanently holds
  `#forced_movement_done?` false, so Proceed With Movement (and the implicit
  auto-run a Wait/Show Text triggers) never resumes — the same "hangs until
  the obstruction clears" family as an impassable-tile target, except there
  is no obstruction here that can ever clear. A genuinely invalid event id
  still no-ops as before. Covered by two new `scripts/rpg2k_scene_check.rb`
  checks, one confirmed to fail against the pre-fix code before the fix.
