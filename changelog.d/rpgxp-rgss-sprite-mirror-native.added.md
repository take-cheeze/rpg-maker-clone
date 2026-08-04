- **`RGSS::Sprite#mirror` is now rendered.** `Sprite#mirror=` is native: LVGL's
  `lv_image` has no flip, so it re-binds the sprite's canvas to a
  horizontally-flipped scratch copy of the bitmap (a per-sprite `Bitmap` held on
  the sprite so the GC keeps it alive) — so `sprite.mirror = true` actually
  flips the sprite instead of being stored-but-ignored. The flip is a snapshot,
  so a sprite that redraws its bitmap contents while mirrored must re-assign
  `bitmap=` to refresh. Completes the LVGL-mappable Sprite transforms (after
  opacity, zoom and angle); the introduced scratch-buffer machinery is what the
  remaining tone/color/src_rect pre-composite will extend. See
  `docs/rpgxp-rgss-api-gap.md`.
