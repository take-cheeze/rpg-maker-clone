- The **Change Map Tileset** (11710) event command is now handled: it swaps the
  current map's chipset to the id in param0. The interpreter records the request
  and `Scene::Map` rebuilds the chipset model and its tile graphic (disposing the
  old bitmap), so passability, terrain and rendering all pick up the new tileset
  at once. The override lasts until the next map load — a teleport rebuilds from
  the destination map's own chipset. Non-blocking, like the other map-mutating
  commands. Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
