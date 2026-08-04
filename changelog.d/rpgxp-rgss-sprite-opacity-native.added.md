- **`RGSS::Sprite#opacity` is now rendered.** `Sprite#opacity=` is native: it sets
  the sprite canvas's LVGL object opacity (`mruby-rgss/src/lib.cxx`), so the
  compositor multiplies the bitmap's alpha by it and `sprite.opacity = n` fades
  actually fade instead of being stored-but-ignored. First of the native
  Sprite-compositing render passes; zoom/angle/mirror (LVGL image transforms) and
  tone/color/src_rect (software pre-composite) follow. See
  `docs/rpgxp-rgss-api-gap.md`.
