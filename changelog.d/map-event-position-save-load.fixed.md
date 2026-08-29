- **A wandered map event's tile position and facing now survive a save/load
  taken on the same map**, instead of always snapping back to the map's own
  editor-placed spawn point on Continue. `Scene::Map#build_event` always
  built a fresh `Game::Character` straight from the map's own `ev.x`/`ev.y`
  with no override path at all, so even a plain Save-then-Continue on the
  exact same map reset every NPC that had walked away from its default
  placement — matching real RPG_RT's own `SaveMapEvent` chunk (x/y/direction
  — ported from a reference implementation's accessor behavior, not
  independently confirmed against genuine RPG_RT under wine), which this
  codebase never modelled the save/load half of
  at all. Fixed with a new `Game::State#map_event_positions`
  (`event_id => [x, y, direction]`, round-tripped through `to_h`/`.load`
  following the existing `common_event_progress` idiom), a new
  `Scene::Map#record_map_event_positions` snapshotting every live event's
  position once per real frame, and a saved-position override in
  `#build_event`. Scoped to the currently-loaded map only — `perform_teleport`
  clears the table before rebuilding the destination's own events, so an
  ordinary map re-visit (leave and return, no save involved) still resets
  every event to its own page default, unlike a genuine save/load. The
  move-route execution index itself (a custom-route event's own in-progress
  step) is not addressed by this fix and remains a separate, open question.
