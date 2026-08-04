- **`RGSS::Sprite#bush_depth` is now rendered.** `Sprite#bush_depth=` fades the
  bottom N rows of the sprite to half opacity in the same pre-composite pass that
  handles mirror/tone/colour/`src_rect` (`spr_bind_display`), so a character
  wading through bushes actually dims below the waist instead of the depth being
  stored-but-ignored. `flash` remains the outstanding Sprite property. See
  `docs/rpgxp-rgss-api-gap.md`.
