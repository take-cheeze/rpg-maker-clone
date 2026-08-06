- A graphic that is nowhere to be found is now reported as missing instead of
  wearing the last decoder's error. `RGSS::Bitmap#initialize` fell back to
  `Bitmap._load_error` / `Bitmap._stbi_error` whenever a name resolved to
  nothing — but a name that matched no file never reaches a decoder, so those
  globals still held some *earlier* image's failure. In practice that was always
  stb's `no SOI`: both `stbi__load_main` and `stbi__info_main` try JPEG first,
  and its header check fails on a PNG's magic without being cleared by the PNG's
  later success. Every missing asset in a PNG game therefore came out as a JPEG
  complaint about a file that was never opened — booting the packed *Pray for
  You* said
  `RPG::Cache: Graphics/Characters/023-Gunner01 did not load (Failed to init bitmap: … (no SOI))`
  for what is simply an RPG Maker XP RTP charset the release does not pack (its
  `Game.rgssad` holds 222 entries, none of them that one) with no RTP installed.
  The loader now clears both diagnostics per load (`Bitmap._begin_load`) and
  records whether any bytes reached a decoder (`Bitmap._decoder_ran?`), so the
  same boot reports
  `not found (tried .png/.jpg/.jpeg/.xyz/.bmp): GAME_DIR "…"; no RTP installed (RTP_DIR is empty); not in the encrypted archive`
  — which names the search root that came up empty, and so the fix.
- Failures now raise `RGSS::Bitmap::LoadError` (a `RuntimeError`, so existing
  `rescue` clauses are unaffected), carrying the path and the reason apart.
  `RPG::Cache` and `Graphics.transition` log the reason alone instead of
  printing the file name twice on the same line.
