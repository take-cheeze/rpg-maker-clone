- **A same-as-characters event stacked with a below/above-characters event on
  the same tile could stop blocking the hero.** RPG2000 already lets two
  events share a tile when their priority types differ (a below-characters
  floor decal drawn under a same-as-characters NPC, say — see
  `rpg2k-priority-type-passability.fixed.md`), but `Scene::Map`'s
  occupied-tile cache (`@event_tiles`) kept only one event per tile — the
  last one indexed — so whichever of the two got built or moved last
  silently decided the whole tile's collision answer. A below-characters
  decal indexed after its same-layer companion masked it outright, letting
  the hero walk straight through a tile a blocking NPC still stood on; the
  decal wandering off its shared tile via a custom move route had the same
  effect, overwriting the cache entry and leaving the stationary same-layer
  event behind it unblocked. `passable?`, `char_passable?`, `char_can_land?`,
  `vehicle_passable?` and `airship_landable?` now consult a new
  `blockers_at`/`@event_tiles_by_pos` index that keeps every live event on a
  tile, not just one, so a same-layer blocker keeps blocking regardless of
  which of its tile-mates was indexed first or last. `@event_tiles` itself is
  unchanged and still answers the "pick one event here" queries (`event_at`,
  the action/touch triggers, encounter suppression). Covered by two new
  `scripts/rpg2k_scene_check.rb` checks.
