- **A map event's own Set Move Route / page-authored custom route now fires
  its Event Touch (trigger 2) page when it steps onto the party, instead of
  silently blocking with no trigger at all.** `Scene::Map#move_autonomous`
  already had a dedicated check for an *autonomous* (Random/Approach/Away)
  move stepping onto the player, but `Game::MoveRoute#do_move` — the engine
  both a Set Move Route and a page's own Custom move-type route share —
  just called `world.passable?` and turned to face any obstacle, with no
  distinction between a wall and the party. Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: a map event's own move-failure handling
  starts a Trigger_collision page whenever the blocked tile is the
  player's, with no guard gating it off while a move route is active
  (unlike the hero's own move-failure handling, whose own touch check *is*
  gated on exactly that —
  confirmed already correct here too, and now documented in `docs/TODO.md`
  with the citation). Fixed by having `do_move` report a new
  `:touched_hero` status — purely a re-classification of an already-refused
  move, so it changes nothing about whether the move itself succeeds, and
  never affects a vehicle's own route since vehicles don't collide with the
  party at all — which `Scene::Map#step_event` turns into the same trigger
  `#move_autonomous` already fires. Covered by new
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb` checks,
  confirmed to fail against the pre-fix code before the fix.
