- **Sprites** showing a palette image, a `src_rect` cell, a mirror, a tone, a
  colour, a flash or a bush depth are now drawn row by row as LVGL renders each
  strip, instead of from a full-colour copy of the image (a promoted palette
  image or a per-sprite effect buffer). The title logo, battle backdrops and
  monsters stay indexed; the pixels on screen are the same.
  `RGSS_DRAW_TIME_SPRITES=0` (environment or build define) turns it off.
