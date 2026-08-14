- **A map event's own page-authored custom move route now resumes at its
  exact command when a save is loaded, instead of restarting from the top.**
  `Scene::Map#build_event` always built a fresh `Game::MoveRoute` at index 0
  from the page's own `move_route` field, with no override path at all — the
  already-fixed wandered-position restore only ever carried tile x/y/facing
  across a save/load, leaving the route's own execution index unmodelled
  (flagged in `Game::State#map_event_positions`' own comment: "plus a
  move-route index this codebase does not attempt to round-trip yet"). Fixed
  with a new `Game::State#map_event_route_index` (event id => `Game::MoveRoute
  #index`), scoped and round-tripped identically to `#map_event_positions`
  (Marshal-save-only, per-map, cleared on `#perform_teleport`), and a new
  `Game::MoveRoute#resume_at(i)` that seeks a freshly-built route to that
  saved cursor — including reproducing the `@commands.size` sentinel a
  finished non-repeating route leaves behind, so a route saved right after it
  naturally finished stays finished on load rather than re-running its last
  step. Scoped away from `Scene::Map#rebuild_events_preserving_positions` (the
  live, in-place page-reselection rebuild any unrelated event's switch write
  can trigger) via a new `restore_route_index:` keyword, so a bystander whose
  own page just changed to a genuinely different route always starts that
  route at index 0 rather than seeking into an index that belonged to its old
  page's route; a bystander whose route did *not* change keeps getting its
  full-fidelity live object back exactly as before. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks, one confirmed to fail against the
  pre-fix code before the fix.
