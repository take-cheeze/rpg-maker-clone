- **`RGSS::Tilemap` now renders the map's regular tiles natively.** `Tilemap` was a
  pure-Ruby property holder; it is now native (`mruby-rgss/src/lib.cxx`):
  `Tilemap.new` builds an `lv_canvas` the size of the viewport and `tilemap_refresh`
  draws the visible tiles of the three `map_data` layers from the `tileset`,
  scrolled by `ox`/`oy` — so the map ground actually renders instead of being
  stored-but-ignored. `tileset=`, `map_data=`, `ox=`/`oy=`, `z=`, `visible`,
  `dispose` are native. **Regular tiles only** for now (id ≥ 384); the seven
  autotiles (id 48–383) and the per-tile priority layering are still stored-only —
  autotile-heavy ground is missing and tiles render on one flat layer. First of the
  Tilemap render slices. See `docs/rpgxp-rgss-api-gap.md`.
