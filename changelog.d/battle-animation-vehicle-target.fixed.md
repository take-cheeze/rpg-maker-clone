- **Show Battle Animation (11210) targeting a vehicle now plays over that
  vehicle's own live position**, instead of silently defaulting to the
  player's. `Scene::Map#animation_target_pixel` (`mruby-rpg2k/mrblib/
  scene/map.rb`) had no case for a vehicle's Move-Event-style target id
  (10002-10004, boat/ship/airship), so it fell into the "map event by id"
  lookup, found nothing (a vehicle slot is never a real map event id), and
  defaulted to the player's own tile — matching yado.tk's own finding that a
  vehicle-targeted Battle Animation reads that vehicle's real x/y, off
  `Game::State` directly, even from a different map than the one on screen,
  the same blind-read quirk the Control Variables vehicle-position fix
  already reproduces for the "character position" operand. Fixed with a new
  `#vehicle_pixel`, reading straight off `Game::Vehicle`'s live `x`/`y`.
  Covered by a new `scripts/rpg2k_scene_check.rb` check, confirmed to fail
  against the pre-fix code before the fix.
