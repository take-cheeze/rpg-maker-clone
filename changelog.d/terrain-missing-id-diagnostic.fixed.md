- **A stale terrain id (a database shrink leaving a chipset cell pointing at a
  terrain row that no longer exists) now logs a diagnostic instead of
  silently falling back to defaults with no trace.** `Scene::Map
  #terrain_row_at` (`mruby-rpg2k/mrblib/scene/map.rb`) used to swallow the
  gap with a bare `rescue StandardError; nil`; it now logs a
  `[RPG2k] Terrain: tile (x, y) references terrain #<id>, which no longer
  exists in the database` diagnostic the first time the stale id is actually
  looked up, matching real RPG_RT's own deferred-until-exercised behaviour
  (it only errors once the player steps onto the specific stale tile, not
  proactively at load time). Deduped per stale tile for the visit so a party
  standing on the tile, or its several per-frame callers (encounter rate,
  terrain damage, bush depth, vehicle passability), don't spam the log.
  Behaviour is otherwise unchanged: the lookup still returns `nil` and every
  caller still falls back to its existing default. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
