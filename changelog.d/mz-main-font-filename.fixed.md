- **RPG Maker MZ:** a project shipping more than one `fonts/*.woff` (its real
  dialogue font plus a separately-subsetted `advanced.numberFontFilename` for
  battle-damage digits, as real MZ releases commonly do) could have every
  window's text silently render through the wrong one — `readdir()` order is
  unspecified, and the loader just took "whichever `.woff` it saw first".
  Found against the real downloaded `EgoicAnswers` release, where the
  95-glyph number-digit subset (ASCII only, no space glyph, no Japanese) won
  over the actual 1MB main font: every window drew a visible box at each word
  boundary and the game's own Japanese dialogue did not render at all.
  `font_dir_first_font` (`mvcanvas.cxx`) now honors `System.json`'s
  `advanced.mainFontFilename` (read by a new `MV.maybe_set_main_font`, `mv.rb`,
  mirroring the existing `encryptionKey` reader) ahead of the old
  first-`.woff`-seen fallback, which still applies unchanged for every project
  (every test bed so far) that ships only one font.
