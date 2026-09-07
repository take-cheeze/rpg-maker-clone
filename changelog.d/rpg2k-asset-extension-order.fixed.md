- RPG Maker 2000/2003 games now resolve a bare graphic name the way their own
  `RPG_RT.exe` does — `.bmp` first, then `.png`, then `.xyz`, with no JPEG
  candidate — so a project shipping both spellings of one asset draws the same
  picture the real runtime draws. Measured against a genuine `RPG_RT.exe` under
  wine for `Title/`, `System/` and `GameOver/` alike. The order is per-runtime
  (`RGSS::Bitmap.extensions`), so RPG Maker XP keeps the png-first list its
  RTP's `.jpg` title screens need.
