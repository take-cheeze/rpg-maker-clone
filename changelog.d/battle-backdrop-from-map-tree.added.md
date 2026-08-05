- Battles are now fought over the **backdrop the game actually specifies**
  instead of a flat dark field. RPG2000 stores this on the map-tree node rather
  than the map: `Game::Backdrop.name_for` reads the node's `backdrop_type` —
  liblcf's BGMType_parent / _terrain / _specific, the editor's 親マップと同じ /
  地形で指定 / 指定する — and `Scene::Map#encounter_backdrop` resolves it against
  the terrain the party is standing on (the terrain row's `background_name`).
  Inheriting maps walk up the tree, which is the common case and does real work:
  491 of Nepheshel's 537 maps are type 0, and 475 of them reach their "black"
  interior backdrop only through a parent, while all 13 of mtf-meido-action's
  maps take the terrain branch instead (Grassland / Desert / Snow Field / ...).
  The walk is bounded and cycle-safe, so a looping map tree ends at the terrain
  rather than hanging the battle.
- A monster that **transforms mid-fight is now redrawn** with the battler it
  became — the combatant carries its `battler_name` and the battle screen
  rebuilds any sprite whose graphic no longer matches, leaving unchanged ones
  alone.
