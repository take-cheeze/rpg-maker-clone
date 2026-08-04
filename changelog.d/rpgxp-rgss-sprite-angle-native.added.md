- **`RGSS::Sprite#angle` is now rendered.** `Sprite#angle=` is native: a Sprite's
  canvas is an LVGL image, so it sets the image rotation via `lv_image_set_rotation`,
  converting RGSS's counter-clockwise degrees to LVGL's clockwise 0.1° units and
  pivoting on the sprite's `ox`/`oy` origin — so `sprite.angle = 90` actually
  rotates the sprite instead of being stored-but-ignored. Follows the native
  `opacity` and `zoom` passes; `mirror` (a software horizontal-flip pass) and
  `tone`/`color`/`src_rect` (a software pre-composite) are the remaining
  Sprite-compositing slices. See `docs/rpgxp-rgss-api-gap.md`.
