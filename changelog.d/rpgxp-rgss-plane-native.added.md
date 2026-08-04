- **`RGSS::Plane` now tiles and scrolls natively.** `Plane` was a pure-Ruby
  property holder; it is now native (`mruby-rgss/src/lib.cxx`): `Plane.new` builds
  an `lv_canvas` the size of the viewport (or screen) and fills it by tiling the
  assigned `bitmap` with the `ox`/`oy` scroll wrapped around it, so map parallax
  and fog planes actually render and scroll instead of being stored-but-ignored.
  `bitmap=`, `ox=`/`oy=`, `opacity=`, `z=`, `visible`, `dispose` are native;
  `zoom`/`blend`/`tone`/`color` are still stored-only (the tile is a straight
  copy). First of the `Window`/`Tilemap`/`Plane` native renderers. See
  `docs/rpgxp-rgss-api-gap.md`.
