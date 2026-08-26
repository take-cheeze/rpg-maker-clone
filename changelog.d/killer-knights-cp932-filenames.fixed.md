- `scripts/download-killer-knights.bash` now extracts kk1.12.zip with
  `unar -e cp932`, matching `rtp_install.bash`'s own RTP unpack. The archive's
  internal file names are Shift_JIS (`Picture/キラーナイツ隊旗.png`,
  `Picture/地名：レスト城.png`, ...); `unar`'s default guess mangled every
  one into mojibake that the LCF/`RPG_RT.ldb`-only checks never notice (none
  of them read a filename a game database points at) but that broke the
  genuine RPG_RT.EXE outright — confirmed by actually running it live under
  wine: it reached the title screen and the opening story scenes fine on a
  plain `unar -q` extraction, then failed to open a Picture file by its exact
  name the moment a map event tried to show one.
