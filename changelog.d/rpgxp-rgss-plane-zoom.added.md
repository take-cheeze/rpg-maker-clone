- **`RGSS::Plane#zoom_x`/`#zoom_y` are now rendered.** The tiled pattern scales by
  sampling the source at the reciprocal rate (nearest-neighbour), so a zoomed
  parallax/fog Plane appears larger or smaller instead of the zoom being
  stored-but-ignored; a zoom of 1.0 keeps the fast integer tiling path. This was the
  last outstanding Plane property, so `Plane` is now fully rendered. See
  `docs/rpgxp-rgss-api-gap.md`.
