- **The RPG2000/2003 field menu** (and its Item, Skill, Equip and Status
  screens) no longer keeps its window contents and full-screen backdrop as
  ARGB pixels. `Bitmap#_defer` now also records `draw_text` and `blend_text`
  in the bitmap font, so these bitmaps hold their text runs and face blits
  and are composed as the screen is drawn, with the same pixels on screen.
  `RGSS_DEFERRED_BITMAPS=0` turns it off.
