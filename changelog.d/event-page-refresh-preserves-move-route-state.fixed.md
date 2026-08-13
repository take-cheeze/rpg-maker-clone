- **An event's Through Mode, Direction Fix, Stop Animation and Transparency
  no longer reset when a *different* event's page flips.** `Scene::Map
  #pages_changed?` is a map-wide check — any Control Switch/Variable write,
  item change or party change that flips *any* event's active page triggers
  `#rebuild_events_preserving_positions`, which rebuilds every event's
  `Game::Character` from scratch via `build_events`. The old-to-new copy loop
  only carried `x`/`y`/`direction` (and, conditionally, an in-progress custom
  route) across that rebuild, so an event whose own page never changed still
  had its Through Mode / Direction Fix / Stop Animation / Transparency
  silently reset to their `Game::Character#initialize` defaults — none of
  which a page ever sets; they only ever change via a Move Route's Through
  Mode, Direction Fix, Stop/Start Animation or Transparency Up/Down
  sub-commands, and are documented (yado.tk) to stick until explicitly
  changed. Fixed by carrying those four fields across the rebuild the same
  way position/direction already are. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (a bystander event's Through Mode,
  Direction Fix, Stop Animation and Transparency all survive an unrelated
  event's switch-triggered page change), confirmed to fail against the
  pre-fix code before the fix.
