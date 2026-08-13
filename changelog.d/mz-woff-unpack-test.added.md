- **The WOFF unpacker now has CI coverage.** `woff_to_sfnt` (the MZ `.woff`
  font unpacker, `mvcanvas.cxx`) previously proved itself only against two real
  TTFs repacked as WOFF and checked by hand, because it needs a redistributable
  font and the test beds ship none — and its result sits behind `game_font()`'s
  process-lifetime cache, so a font dropped into a test's `fonts/` dir is
  invisible once any earlier test has already drawn text. `MV::Font.unpack_woff`
  and `MV::Font.smoke_test` (new, test-only bindings) reach the unpacker and a
  fresh `stb_truetype` rasterisation directly, bypassing that cache.
  `mruby-mvjs/test/mz_test.rb` hand-authors the smallest font that can prove the
  pipeline — one glyph mapped from `'A'`, built table-by-table the way the MV
  image fixtures are — wraps it as WOFF, and checks the unpacked sfnt comes back
  byte-for-byte identical and rasterises the same real ink as the bare sfnt.
