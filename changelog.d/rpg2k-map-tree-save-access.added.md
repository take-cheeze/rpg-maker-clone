- **The map tree's per-map Save setting (map_properties field 33) is now
  applied.** RPG_RT lets a map's editor properties pin the menu's Save command
  to Allow or Forbid, or inherit whatever the parent map resolves to; that
  tri-state was parsed off `RPG_RT.lmt` but never fed into the runtime, so a
  map that forbade saving in the editor never actually blocked it in play.
  `Game::MapAccess.save_allowed?` walks "same as parent" nodes up the tree the
  same way `Game::Backdrop.name_for` already does for `backdrop_type`,
  defaulting to Allow at the root or on a loop. `Scene::Map` recomputes
  `Game::State#save_access` from it on the initial map load and on every
  Teleport, matching RPG_RT: a `Control Save Access` event command can still
  override it for the rest of that map's visit, but the next map load
  re-derives it from the tree again. Covered by nine new checks in
  `scripts/rpg2k_logic_check.rb` (Allow/Forbid, single- and multi-level
  inheritance, root/unknown-map/loop/self-parent defaults, and a node missing
  the field).
