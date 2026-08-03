- RPG Maker **VX Ace** encrypted-archive (`Game.rgss3a`, RGSSAD version 3)
  support. `RPGXP::RGSSAD` now decrypts the v3 layout in addition to v1: a
  plaintext 32-bit seed in the header derives a base key (`seed * 9 + 3`), a
  fixed-key table of entry records (absolute offset, size, per-file data key and
  name) is walked to a zero-offset terminator, and each file's data is decrypted
  with its own per-file key using the same routine as v1. `RPGXP::RGSSData`
  transparently falls back to a `.rgss3a` archive (already tried by `RGSSAD.find`)
  when a `.rxdata` is not loose on disk. New `RGSSAD.pack_v3` builds v3 archives
  (the inverse of the reader, used as the test fixture builder). Covered by new
  `mruby-rpgxp/test` round-trips and by `scripts/rpgxp_testbed_check.rb`, which
  now packs the real test bed as both `.rgssad` and `.rgss3a` and reloads the
  whole database through each.
