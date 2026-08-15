- **Hero Touch (and Event Touch) no longer fires when the party and a moving
  event trade tiles in one step** — the party walking right onto an event's
  tile the same frame the event walks left onto the party's own (pre-move)
  tile. RPG_RT invalidates the hit-test for this exact configuration (no
  trigger fires either way), but `Scene::Map#update` decided an
  autonomous/route-driven event's move (`step_events`, including its own
  refusal to step onto the party's tile) *before* deciding the party's own
  move (`step_movement`) for the same frame, so the event's refusal always
  saw the party's stale, pre-move position — the crossing collapsed into an
  ordinary "party walks onto a stationary touch event" outcome, firing Hero
  Touch when neither trigger should. Fixed without reordering the two steps:
  `Scene::Map#player_intended_target` snapshots the party's own input-driven
  move target right before `step_events` runs, using the exact early-outs
  `step_movement` itself bails out on, so `#move_autonomous` and
  `Game::MoveRoute#do_move`'s hero-tile refusal can recognise a same-frame
  "event's target is the party's tile *and* the party's target is the
  event's tile" crossing and flag it (`e[:crossed_hero_this_frame]`) instead
  of firing Event Touch; `step_movement`'s own `event_at` check consults the
  same flag and withholds Hero Touch too, falling through to the ordinary
  passability check (a same-layer event still silently blocks the step).
  Covered by five new `scripts/rpg2k_scene_check.rb` checks, including a
  regression guard that an event's earlier, separate-frame refusal does not
  suppress a later, genuinely non-crossing Hero Touch.
