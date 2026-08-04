- **`RGSS::Tilemap` now renders autotiles.** Building on the regular-tile render,
  `tilemap_refresh` now also assembles the seven autotiles (tile ids 48–383): each
  32×32 autotile tile is built from its four 16×16 quads using the RMXP 48-shape
  quad table (`AUTOTILE_QUADS`, derived from mkxp's `autotileRects`), read from the
  `autotiles[0..6]` bitmaps — so water/terrain ground fills in instead of leaving
  holes. Per-tile priority layering and autotile animation are still pending (one
  flat layer, first animation frame); `flash_data` is ignored. See
  `docs/rpgxp-rgss-api-gap.md`.
