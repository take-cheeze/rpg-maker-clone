- **`RGSS::Sprite#blend_type` is now rendered.** `Sprite#blend_type=` maps RGSS's
  0/1/2 (normal / additive / subtractive) onto the sprite canvas object's LVGL
  blend mode (`lv_obj_set_style_blend_mode`), which the compositor uses when
  drawing the sprite over the scene — so additive/subtractive effects (animations,
  magic, weather) blend instead of being stored-but-ignored. `bush_depth` and
  `flash` remain the outstanding Sprite properties. See
  `docs/rpgxp-rgss-api-gap.md`.
