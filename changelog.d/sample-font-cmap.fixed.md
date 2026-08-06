- **Fixed: the test beds' font crashed on any character outside ASCII.** Its
  cmap format-4 header wrote `entrySelector` as 0 where the spec requires
  `floor(log2(segCount))`, and stb_truetype drives its binary search from that
  field rather than from `segCount` — so a lookup above the covered range never
  advanced past the first segment and tripped an assertion inside
  `stbtt_FindGlyphIndex` instead of resolving to "no glyph". Both beds shipped
  the font, so any non-ASCII game text would have hit it; nothing had, until the
  new shop smoke test drew `Window_ShopNumber`'s multiplication sign. All three
  search fields are now computed from `segCount`, and the font carries a `×`
  glyph of its own so the corrected search is exercised on a covered codepoint
  above ASCII as well as a missing one.
