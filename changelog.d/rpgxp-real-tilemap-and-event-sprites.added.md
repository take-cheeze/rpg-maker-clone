- RPG Maker XP maps now draw the project's **real tileset** instead of
  placeholder colour blocks. `Scene::Map` builds the same objects RMXP's
  `Spriteset_Map` does: a native `RGSS::Tilemap` fed the tileset graphic, the
  seven autotiles and the map's data/priority Tables (so regular tiles are
  blitted from the tileset, autotiles are assembled from their quads and
  animated, and priority tiles sort above the characters), plus one sprite per
  event drawn from its active page's graphic — a `Graphics/Characters` sheet, or
  the tile id when the page uses a tile instead. An event whose graphic is empty
  now draws nothing, as in RMXP, rather than the red marker the placeholder
  renderer painted on it. Characters stack by the screen row they stand on
  (RMXP's `screen_z`), so overlapping characters no longer draw in an arbitrary
  order, and `always_on_top` pages sort above the priority layer. Verified
  against the genuine RGSS runtime with `scripts/compare-rpgxp-wine.bash`.
