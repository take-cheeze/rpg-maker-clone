- **A parked boat, ship or airship now blocks the hero and map events again**,
  instead of being fully walk-through. `#char_passable?`/`#char_can_land?`
  (a map event's own autonomous/custom-route movement, and the player's own
  forced Set Move Route mirror) and the hero's own manual-input `#passable?`
  only ever consulted `@event_tiles`, built solely from map events — an
  unridden vehicle was never in it, so the party and every map event could
  walk straight onto or through its tile. Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: its movement-blocking check blocks every mover, the
  player included, on a parked Boat/Ship's own tile, but only checks the
  Airship for a non-player mover — a walking hero passes clean over one,
  while a map event's own movement (and the player's forced-route mirror)
  is stopped by all three vehicle types alike. A new
  `Scene::Map#vehicle_blocks?(x, y, block_airship:)` closes the gap in all
  three functions, gated on that same player-vs-everyone-else split. A
  ridden vehicle's own movement (`#vehicle_passable?`/`VehicleWorld`) is
  untouched. Covered by two new `scripts/rpg2k_scene_check.rb` checks,
  confirmed to fail against the pre-fix code before the fix.
