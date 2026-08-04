- **`RGSS::Sprite#tone` and `#color` are now rendered.** `Sprite#tone=` (an RGSS
  `Tone`: grey desaturation toward luminance + signed RGB offset) and `#color=` (a
  `Color` overlay applied at its alpha) are native — they bake the effect into the
  same per-sprite scratch bitmap the mirror pass introduced (`spr_bind_display`),
  so `sprite.tone = Tone.new(...)` / `sprite.color = Color.new(...)` actually tint
  and flash the sprite instead of being stored-but-ignored. The effect is a
  snapshot (re-assign `bitmap=`/`tone=`/`color=` to refresh after an in-place
  `tone.set`). `src_rect`, `bush_depth`, `blend_type` and `flash` remain the
  outstanding Sprite properties. See `docs/rpgxp-rgss-api-gap.md`.
