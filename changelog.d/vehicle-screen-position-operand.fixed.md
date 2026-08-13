- **A vehicle's screen X/Y now resolve through the Control Variables
  "character position" operand**, instead of always reading 0. A vehicle's
  map id/x/y/facing (attrs 0-3) were already fixed to read correctly from a
  different map than the one it currently occupies, but the screen-coordinate
  selectors (attrs 4/5) fell through `Scene::Map#character_screen_position`'s
  hero/map-event-only branches to the same degenerate 0 an unresolvable
  reference gets — the fix that landed the other four attrs explicitly scoped
  this pair out as needing a scene-side camera hook. `#character_screen_position`
  now recognises refs 10002-10004 (boat/ship/airship) via a new
  `#vehicle_pixel`, which reads the ridden vehicle's interpolated pixel
  position (in lockstep with the hero) or a parked one's tile position — the
  same rule `#draw_vehicles` renders a vehicle's sprite by — and answers nil
  (falling back to 0, matching an unresolvable map event) for a vehicle not
  currently on the loaded map. Covered by a new `scripts/rpg2k_scene_check.rb`
  check, confirmed to fail against the pre-fix code before the fix.
