- **A forced move route (Move Event / Set Move Route) on the player, an event
  or a vehicle now keeps stepping while the event that issued it is still
  busy.** RPG_RT does not pause a route it was told not to wait for (no
  Proceed With Movement) just because the same event keeps running its next
  commands — that is the ordinary "walk in the background while the
  narration continues" idiom, and Nepheshel's own opening uses exactly this
  shape: a Move Event on the hero, then several Show Text / Name Input
  commands with no Proceed With Movement in between. `Scene::Map#update`
  only stepped `step_player_route` / `step_events` / `step_vehicle_routes`
  from its non-busy branch, so a route issued by the currently-running event
  could never step until that whole event finished — every such route sat
  frozen for as long as its own dialogue lasted and then played out all at
  once the instant the event ended, rather than animating alongside it.
  These now step every frame regardless of `event_busy?` (still skipped
  during an actual Proceed With Movement wait, which already owns stepping
  them via `step_forced_movement`); `step_event`'s own busy check now exempts
  a `forced_route` the same way, and the party's own pixel slide
  (`advance_player_slide`) moved out to keep pace with it, preserving the
  pre-existing one-frame gap between a route landing and its next queued step
  via a new `@slide_was_active` flag. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
