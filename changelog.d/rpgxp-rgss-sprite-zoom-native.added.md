- **`RGSS::Sprite#zoom_x` / `#zoom_y` are now rendered.** `Sprite#zoom_x=`/`zoom_y=`
  are native: a Sprite's canvas is an LVGL image, so they set its scale via
  `lv_image_set_scale_x/y` (where 256 = 1.0), converting the RGSS float multiplier
  to that fixed point — so `sprite.zoom_x = 2.0` actually doubles the sprite
  instead of being stored-but-ignored. Follows the native `opacity` pass; angle,
  mirror, and tone/color/src_rect are the remaining Sprite-compositing slices. See
  `docs/rpgxp-rgss-api-gap.md`.
