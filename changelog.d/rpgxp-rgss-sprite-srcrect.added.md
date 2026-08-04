- **`RGSS::Sprite#src_rect` is now rendered, and `Sprite#update` is native.**
  `src_rect=` crops the sprite to a sub-rectangle of its bitmap by extending the
  per-sprite pre-composite (`spr_bind_display`): the scratch bitmap becomes that
  region (combined with any mirror/tone/colour), reused across frames to avoid GC
  churn. `Sprite#update` — previously absent — is native and re-composites when a
  `src_rect` is set, so the per-frame in-place `src_rect.set` that character
  sprites do (to pick the animation cell out of a charset) actually changes the
  shown frame instead of displaying the whole spritesheet. `bush_depth`,
  `blend_type` and `flash` remain the outstanding Sprite properties. See
  `docs/rpgxp-rgss-api-gap.md`.
