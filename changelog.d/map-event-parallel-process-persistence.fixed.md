- **A Map Event's own Parallel Process now survives a genuine Save/Continue
  on the same map**, instead of always restarting from the top — the one gap
  cycles #191/#192's own foreground/Common-Event-Parallel-Process call-stack
  persistence deliberately left open (a Map Event's own Parallel Process,
  distinct from a Common Event's, had no persistence mechanism at all, not
  even the older, coarser `Game::Interpreter#resumable_index`-style cursor,
  since no such cursor ever existed for one). `LCF::Schema::SAVE_MOVABLE`
  gained field 108 (`parallel_event_execstate`, liblcf's own `SaveMapEvent`
  field), the same `SAVE_EVENT_EXEC_STATE` struct chunks 113/114 already use,
  nested inside chunk 111's own per-event `Array2D`. `Game::State` gained
  `#map_event_exec` (a `{event id => call-stack frames}` Hash mirroring
  `#common_event_exec`'s own shape, but — unlike it — scoped to the currently
  loaded map only and reset on every `#perform_teleport`, since a map event's
  own id repeats across maps). `Scene::Map#record_parallel_progress` (which
  used to no-op outright for a map event's own Parallel Process) now
  snapshots it there every tick, and `#new_parallel` consults it the same way
  it already consults `#common_event_exec`. An ordinary Transfer Player still
  always restarts a map event's own Parallel Process fresh, unchanged — only
  a genuine `.lsd` Save/Continue on the same map reaches the new mechanism.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` (the schema-level
  `to_lsd`/`from_lsd` round trip, mid a nested Call Event) and
  `scripts/rpg2k_scene_check.rb` (a fresh `Scene::Map` genuinely resuming
  from the captured call stack rather than restarting). See docs/TODO.md's
  cycle #193 entry.
