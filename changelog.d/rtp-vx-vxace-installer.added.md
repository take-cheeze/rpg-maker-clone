- **RPG Maker VX and VX Ace RTP installers**, `scripts/rtp_vx_install.bash` and
  `scripts/rtp_vxace_install.bash`, join the RPG2000/2003/XP ones and now run
  alongside them in CI's "Download RTP" step. Both RTPs turn out to be
  genuinely freely-redistributed from `cdn.tkool.jp` too (`vx_rtp202.zip`,
  `vxace_rtp100.zip` — VX Ace's alone is ~186 MiB, since its BGM ships as
  `.ogg` rather than `.mid`), contrary to the assumption in the RPG2003
  installer entry above that only 2000/2003/XP had a free download; the
  installer filenames just don't follow the same naming pattern as the other
  three, which is what hid them from an initial CDN probe. Both are Inno Setup
  installers like XP's, so `/verysilent` is enough — no custom InstallShield
  response file needed. Confirmed by a real install under wine: they register
  `Software\Enterbrain\RGSS2\RTP` value `RPGVX` and
  `Software\Enterbrain\RGSS3\RTP` value `RPGVXAce` respectively, exactly the
  keys and value names `rgss_rtp_path()` in `src/main.cxx` already reads (the
  RPG2000/2003 gap `rtp_path()` has does not apply here), so VX and VX Ace
  projects using the stock RTP are found by the engine with no further code
  changes. MV and MZ still have no equivalent — see the RPG2003 installer
  entry.
