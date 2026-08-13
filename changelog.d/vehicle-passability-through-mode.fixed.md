- **A boarded boat or ship can no longer overlap a below/above-characters
  event's tile.** `Scene::Map#vehicle_passable?`'s boat/ship branch reused
  the hero's own priority-type-gated occupancy test
  (`blocker[:layer] == LAYER_SAME || blocker[:overlap_forbidden]`), so a
  below-characters event with a passable graphic — which the walking hero
  correctly overlaps via that same gating — was silently sailed straight
  through by a ship too. RPG_RT's ship rule is a real divergence from the
  hero's: a ship ignores priority type entirely and is blocked by *any*
  event unless that event's own move route has Through Mode on. The blocker
  check is now `blocker && !blocker[:char].through`, reading the same
  `Game::Character#through` accessor the hero's own Through Mode already
  uses; the airship branch (which flies over every event, unaffected) and
  the hero's own passability rules are untouched. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
