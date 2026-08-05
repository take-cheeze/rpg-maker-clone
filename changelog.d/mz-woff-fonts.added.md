- MV/MZ: `.woff` fonts load, so an MZ game's text draws at all. The canvas text
  loader looked only for `.ttf`/`.otf` under a game's `fonts/`, and RPG Maker MZ
  projects ship `.woff` (`mplus-1m-regular.woff`), so it found no font and every
  window came out blank. WOFF 1.0 is now unpacked to the sfnt it wraps — a
  table-by-table container whose tables are stored raw or zlib-deflated, and the
  zlib decoder stb_image already provides does the work, so no new dependency —
  and handed to stb_truetype as before. A bare `.ttf`/`.otf` is still preferred
  when a game ships one.
- MV/MZ: a font that cannot be used now says so on stderr instead of silently
  drawing nothing: WOFF2 (a different format needing Brotli and a transformed
  `glyf` table) is named as unsupported rather than half-parsed, as are a
  malformed WOFF and a font stb_truetype rejects.
