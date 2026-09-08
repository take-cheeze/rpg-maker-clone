- **Cut the Wio Terminal firmware's flash overflow by ~21% (361 KB), with
  zero behavior change to any existing target.** The mruby cross build and
  the standalone `uni-algo` build never passed `-ffunction-sections
  -fdata-sections`, so the linker's own `--gc-sections` could only discard a
  whole object file at once, not individual unused functions/data within
  one — fixed, which as a side effect also confirms ADR 103's flagged
  `iterm.cxx`/`sixel.cxx` dead-code gap is already closed (both are now
  provably absent from the real linked image). The embedded Shinonome font
  also generated a second, serif kanji face (`MINCHO`) nothing ever looked
  up — dropped outright — and `gen_shinonome_data.rb` gained a real,
  opt-in mechanism (`SHINONOME_GLYPH_TEXT_FILE`) to subset the main kanji
  face to only the glyphs a given text corpus actually uses, rather than
  always embedding the entire ~6,900-glyph JIS0208 table. See ADR 105.
