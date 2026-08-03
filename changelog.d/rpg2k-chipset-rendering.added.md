- **RPG2000 chipset rendering** — `Scene::Map` now blits the lower/upper tile
  layers from the map's real `ChipSet/<name>` graphic instead of solid colour
  blocks. `Game::ChipsetLayout` ports EasyRPG Player's `TilemapLayer` geometry:
  single-chip lower (block E) / upper (block F) tiles, water (blocks A/B) and
  terrain (block D) autotiles assembled from four 8×8 quarter-tiles per the
  combination encoded in the tile id, the animated block-C tiles, and
  water/animation frame cycling driven by the chipset's animation type/speed.
  Missing chipset images fall back to the previous colour blocks. Geometry is
  pinned by the new `scripts/rpg2k_render_check.rb`. See ADR 0016.
