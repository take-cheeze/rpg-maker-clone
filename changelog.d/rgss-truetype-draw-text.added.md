- RGSS (RPG Maker XP/VX) text now draws with the game's **TrueType font**.
  `Bitmap#draw_text`/`#text_size` rasterise glyphs with stb_truetype, picking a
  `.ttf`/`.otf`/`.ttc` under the project's `Fonts/` folder by `RGSS::Font#name`
  (a lenient family match, else the first font found) and sizing them by
  `#size`, honouring bold, italic, outline (from `out_color`) and shadow.
  When no font file is reachable, drawing falls back to the built-in shinonome
  bitmap font as before, so text always renders. The single stb_truetype
  implementation now lives in `mruby-rgss` (`src/lib.cxx`); `mruby-mvjs`, which
  already used stb_truetype for MV canvas text, links against it instead of
  compiling its own copy. Covered by new checks in `mruby-rgss/test/test.rb`.
