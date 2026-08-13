- **An airship can no longer land on a tile a map event occupies**, unless
  that event's own move route has Through Mode on. `Scene::Map
  #airship_landable?` gated its blocker check on the hero's own priority-type
  occupancy test (`blocker[:layer] == LAYER_SAME || blocker[:overlap_forbidden]`),
  so a below/above-characters event — which airborne flight already ignores
  entirely, since `#vehicle_passable?`'s airship branch never reads
  `@event_tiles` — was also silently landable on, the same way the walking
  hero correctly overlaps it. RPG_RT's landing rule is the vehicle-specific
  one already fixed for a boarded boat/ship: any layer blocks, priority-type/
  `overlap_forbidden` gating is ignored entirely, and only the blocking
  event's own Through Mode lets it through. The blocker check is now
  `blocker && !blocker[:char].through`, matching `#vehicle_passable?`'s
  boat/ship branch exactly; flying itself, and the terrain's own
  `airship_land` flag, are untouched. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the pre-fix
  code before the fix.
