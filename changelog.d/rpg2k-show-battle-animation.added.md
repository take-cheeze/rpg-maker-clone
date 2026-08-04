- **Show Battle Animation (11210).** The event command that plays a battle
  animation over a character on the map is now handled at the timing level. The
  interpreter records the request (animation id, target character, wait flag) on
  `battle_animation` — which a future map-animation renderer will read to draw it —
  and, when the "wait until it finishes" flag is set, suspends on an `:animation`
  wait. `Scene::Map` holds the event for the animation's on-screen length (its
  database `battle_anime` cell count × a per-cell hold, falling back to a nominal
  length for an unknown animation), then resumes — so a cutscene that waits on an
  animation paces the same as RPG_RT even though the animation itself is not drawn
  yet (native renderer work still to come). Covered by new checks in
  `scripts/rpg2k_logic_check.rb` (the command records its request and pauses only
  with the wait flag) and `scripts/rpg2k_scene_check.rb` (the wait holds the event
  and then resumes it).
