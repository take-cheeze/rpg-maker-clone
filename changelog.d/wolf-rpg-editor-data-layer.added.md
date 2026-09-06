- **WOLF RPG Editor (ウディタ/Woditor)** projects are now recognised and
  playable at a basic level: the whole database loads (`Game.dat`,
  `MapTree.dat`, `TileSetData.dat`, the three databases, `CommonEvent.dat` and
  every map, across both the Shift_JIS 2.2x format and the UTF-8/LZ4-packed
  3.5+ one) and New Game opens the start map, sized from the project's own
  screen setting, with the hero walking real per-tile passability. Tiles
  render as passability-coloured blocks; events do not run yet. See
  `docs/adr/0064-wolf-rpg-editor-data-layer.md`.
