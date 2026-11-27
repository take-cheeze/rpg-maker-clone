- **The map's tile layers are one recorded draw each.** `Bitmap#tile_grid`
  draws the visible RPG2000 tiles from a three-plane `Table` of tile ids and
  the chipset, laying chips out as `Game::ChipsetLayout.quads` does, so a
  deferred map layer holds one draw instead of one per chip, and the two
  cached tile buffers are gone. On the Wio build with the ROM class graph, New
  Game's first map frame needs 127 KB of live heap instead of 161 KB.
