- **`Scene::Map#record_map_event_positions` no longer allocates a position
  Array for every live map event on every single frame, unconditionally.**
  Another follow-up from the `RGSS::Profiler.stats[:object_types]`
  investigation: this snapshot (`Game::State#map_event_positions`, read back
  on a same-map Save/Continue) ran every frame for every event regardless of
  whether anything had moved, and built the identical `[x, y, direction]`
  tuple *twice* — once for `map_event_positions`, once more for the
  positionally-redundant `@event_last_position`. Now it compares against the
  Array already sitting in `map_event_positions` first: a stationary event
  (the common case — an idle NPC or a decoration moves only on its own move
  route's own schedule, not every frame) keeps the same Array object across
  frames instead of getting a fresh equal one, and `@event_last_position`
  shares that same object rather than a second copy. Neither hash's entries
  are ever mutated in place elsewhere (only reassigned wholesale), so sharing
  the reference changes nothing any reader can observe — including
  `Game::State#to_lsd`, which only ever reads the three values back out.

  Measured with the same temporary per-frame instrumentation pass (reverted
  before commit) used for the earlier `Scene::Map` draw-path fixes, A/B on
  the identical deterministic Nepheshel run: Array allocations 96.2 → 94.2
  per frame on this particular run's mostly-scripted opening sequence, where
  few of the map's events are actually holding still — the win scales with
  how many on-screen events are idle in any given frame, so it grows in
  ordinary gameplay away from a scripted intro.

  Verified against `scripts/rpg2k_command_soak.rb` (368,332 real event
  commands across both Nepheshel variants), `scripts/rpg2k_scene_check.rb`
  (which exercises the saved-position-wins-over-page-default restore path
  this snapshot feeds), and the rest of the RPG2000 logic/render checks, all
  unaffected.
