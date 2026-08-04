- Two more RPG2000 event commands are now handled. **Change Event Location**
  (10860) instantly places a character on the current map at a tile — the target
  is the player (10001), "this event" (0 / 10005) or a map event by id, and the
  x / y come either from the command's constants or (appointment mode 1) from two
  variables. **Trade Event Locations** (10870) swaps the tiles of two such
  characters. Both are non-blocking: the interpreter queues the request and
  `Scene::Map` applies it after `#update`, snapping the target (cancelling a
  half-finished player step and keeping a forced route's mirror in sync) and
  refreshing the occupied-tile cache so collision and the event marker follow.
  Vehicle targets stay unmodelled. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
