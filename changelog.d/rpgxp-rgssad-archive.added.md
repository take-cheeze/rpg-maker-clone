- RPG Maker **XP** encrypted-archive support — a packed release (a `Game.rgssad`
  with no loose `Data/` folder) now loads. A new pure-Ruby `RPGXP::RGSSAD` reader
  (`mruby-rpgxp/mrblib/rgssad.rb`) decrypts the version-1 RGSSAD format (XP's
  `Game.rgssad`, and VX's same-format `Game.rgss2a`): the rolling
  `key = key * 7 + 3` obfuscation over the entry table and per-file data, seeded
  from `0xDEADCAFE`. `RPGXP::RGSSData` consults the archive when a `.rxdata` file
  is not present loose on disk (loose files shadow the archive, matching RGSS),
  and `src/main.cxx` now recognises a packed project (`Game.ini` + a
  `Game.rgssad`/`.rgss2a`/`.rgss3a`) for the 640×480 window sizing. Implemented
  with byte-wise arithmetic only (no bignum bitwise ops, no `Integer#chr`) so it
  runs on the trimmed mruby, and covered both by `mruby-rpgxp/test` (encode →
  decode round-trip, real Marshal data through the archive, bad-header/version
  rejection) and by `scripts/rpgxp_testbed_check.rb`, which packs the real test
  bed's `Data/*.rxdata` into an archive and loads the whole database back through
  it byte-for-byte. VX Ace's version-3 `Game.rgss3a` is detected but not yet
  decoded.
