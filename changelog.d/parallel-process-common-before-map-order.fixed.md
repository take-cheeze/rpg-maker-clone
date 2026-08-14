- **A common event's own Parallel Process now advances before any map
  event's Parallel Process on the same frame, matching real RPG_RT's fixed
  update order.** `Scene::Map#build_parallels` used to push every map event's
  parallel process into `@parallels` before any common event's, so a common
  event's write this frame (a gate switch, a shared variable) was not
  visible to a map event's own parallel process reading it until the
  *following* frame. Verified against EasyRPG Player's actual C++ source:
  `Game_Map::Update` always calls `UpdateCommonEvents()` before
  `UpdateMapEvents()`, with no interleaving by id across the two groups.
  Fixed by swapping the two loops' order in `#build_parallels`; each loop's
  own internal (ascending id) ordering is unchanged. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
