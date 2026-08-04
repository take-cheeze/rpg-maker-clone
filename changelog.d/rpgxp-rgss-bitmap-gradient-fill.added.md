- **`RGSS::Bitmap#gradient_fill_rect` is now implemented.** It fills a rect with a
  linear gradient from `color1` to `color2` — left-to-right, or top-to-bottom with
  the `vertical` flag — and supports both the `(rect, c1, c2, vertical=false)` and
  `(x, y, width, height, c1, c2, vertical=false)` signatures, matching RGSS. Scripts
  that draw HP/gauge bars and gradient backgrounds now render them. Covered by a
  `mruby-rgss/test` unit test (Bitmap ops run headless). `hue_change` is the last
  missing Bitmap method. See `docs/rpgxp-rgss-api-gap.md`.
