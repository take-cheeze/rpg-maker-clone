- **A Map Event's own Parallel Process no longer restarts from the top when
  a *different* event's page flips.** `Scene::Map#pages_changed?` is a
  map-wide check — any Control Switch/Variable/item/party write that flips
  *any* event's active page runs `#rebuild_events_preserving_positions`,
  which rebuilds every event's `Game::Character` and, via `#build_parallels`,
  every parallel-process interpreter, event 1's parallel process included
  even though event 1's own page never changed. `#build_parallels` had no
  reuse mechanism for a Map Event's own parallel process at all (only a
  Common Event's, keyed by common-event id, already survives this kind of
  rebuild), so the bystander event's Parallel Process silently lost its
  entire in-flight state — call stack, a paused Wait's countdown, everything
  — and restarted at index 0 on every unrelated page flip anywhere on the
  map. Fixed with a new `preserve_map_events:` keyword on `#build_parallels`,
  passed only by `#rebuild_events_preserving_positions` (a same-map, in-place
  page reselection, where a map event's own id still means the same thing
  before and after) and left off at the other two call sites — the initial
  build and a genuine Transfer Player — where a map event's parallel-process
  id means nothing carried over from a different map/visit and a fresh
  restart stays correct, matching the existing, still-passing "a map event's
  parallel process always gets a brand-new interpreter every visit" check.
  When set, a still-running Parallel Process whose own page selection did not
  move (same `commands` array, checked by object identity) keeps its
  interpreter across the rebuild; one whose own page *did* just change still
  gets a fresh interpreter either way, matching yado.tk's "always restarts
  from the top on every re-trigger". Covered by a new
  `scripts/rpg2k_scene_check.rb` check (a bystander event's Parallel Process
  — mid-Wait — keeps its marker-A/marker-B command position and in-flight
  countdown intact across an unrelated event's switch-triggered page change),
  confirmed to fail against the pre-fix code (marker A re-running) before the
  fix.
