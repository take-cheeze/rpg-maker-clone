- **VX / VX Ace `Tilemap`** now draws an A2 table (counter) tile's "leg": the
  8px overhang that spills past the tile's own 32×32 box into the map row
  below it, matching real RPG Maker VX/VX Ace (and mkxp, the reference used to
  derive it — MV's corescript inherited the tile geometry but drives this
  particular effect through a different, JS-only mechanism). Pure arithmetic,
  exposed as `RGSS::Tilemap.vx_table_leg_quads` and pinned in `mruby-rgss/test`
  the same way `vx_tile_quads` is.
