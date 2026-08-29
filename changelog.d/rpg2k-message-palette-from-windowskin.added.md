- **Message text blended with the windowskin** — `\c[n]` message colours now
  take the game's own System windowskin: instead of a flat sampled colour, the
  message glyphs are filled from the windowskin's colour swatch, so the swatch's
  shading blends into the text the way RPG2000 draws it. A new native
  `Bitmap#blend_text` lays glyphs out like `draw_text` (the shinonome bitmap font
  RPG2000 uses, or the TrueType path for XP/VX games) but fills each covered
  pixel from a source swatch region, sampling by vertical position so a shaded
  swatch reads as a top-to-bottom gradient. `Game::MessagePalette` gives the
  swatch cell for each colour (a 10×2 grid of 16×16 cells from y = 48 in the
  160×80 System image) and `Scene::Map` blends each run against it, falling
  back to a flat colour only when no windowskin loaded or for an out-of-range
  index. Swatch geometry is pinned by `scripts/rpg2k_render_check.rb` and the
  render path (blend vs flat fallback) by `scripts/rpg2k_scene_check.rb`. ADR
  0021's side-by-side comparison against a genuine RPG_RT.exe under wine
  independently confirmed the mechanism itself — a shadow glyph offset +1,+1
  from the System shadow block, then the glyph filled from the colour
  swatch — against the flat-white text this build drew before.
