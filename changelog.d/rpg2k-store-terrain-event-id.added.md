- **Store Terrain ID** (10910) and **Store Event ID** (10920) event commands are
  now handled. Both take a tile position (as constants or from variables) and
  write a lookup into a variable: the terrain tag of the tile's lower-layer chip
  (read from the chipset's terrain table via the same chip index as passability),
  or the id of the event standing on that tile (0 when none). The interpreter
  queries the running map through a new `map_info` hook that `Scene::Map`
  provides. Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
