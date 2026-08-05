- The MV/MZ test beds ship a font, so their text actually renders.
  `scripts/gen-sample-font.py` authors a 5x7 dot-matrix face covering ASCII
  32..126 — hand-assembled sfnt tables (cmap/glyf/head/hhea/hmtx/loca/maxp/name/
  post), each lit cell emitted as a square contour — which is entirely ours and
  therefore committable where the RTP fonts are not. The MZ bed gets it as
  `fonts/Sample.woff` (what real MZ projects ship, so CI now exercises the WOFF
  unpacker end to end) and the MV bed as `fonts/Sample.ttf`.
- MZ: the host now provides `FontFace`. `FontManager.startLoading` builds one the
  moment a project names a font in `System.advanced`, and the undefined
  constructor threw inside `Scene_Boot.onDatabaseLoaded` — so the bed naming its
  own font would have killed the boot. The shim satisfies the engine's
  bookkeeping only; glyphs are still rasterised natively from the game's `fonts/`
  directory.
- MZ: `scripts/mz_testbed_check.rb` now fails when `System.advanced`'s font
  filenames name a file that is not in `fonts/` — a dangling name means a stalled
  boot or blank text everywhere, neither of which is visible in a JSON shape
  check.
