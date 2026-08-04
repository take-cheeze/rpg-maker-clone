- **`RGSS::Plane#tone`, `#color` and `#blend_type` are now rendered.** `tone=` and
  `color=` bake an RGSS tone (grey desaturation + RGB offset) and a colour overlay
  into the tiled buffer per pixel (the same maths Sprite uses), and `blend_type=`
  maps 0/1/2 onto the plane canvas's LVGL blend mode. Combined with the already-native
  `opacity=`, a fog/parallax Plane now renders its tint and composites additively
  instead of the effects being stored-but-ignored. `zoom_x`/`zoom_y` (scaled tiling)
  remain the outstanding Plane properties. See `docs/rpgxp-rgss-api-gap.md`.
