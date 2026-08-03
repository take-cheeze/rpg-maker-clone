- RPG Maker **XP** encrypted archives with large entries now load on the native
  (mruby) runtime. `RPGXP::RGSSAD#decrypt_data` (`mruby-rpgxp/mrblib/rgssad.rb`)
  had accumulated the whole decrypted entry into a single per-byte `Array`, which
  overflowed mruby's array-length cap (`MRB_ARY_LENGTH_MAX`, 131072) on any
  archived file bigger than 128 KB — real games pack maps, `Animations.rxdata`
  and graphics well past that, so booting them raised
  `ArgumentError: array size too big`. The decryptor now packs the plaintext in
  bounded chunks and joins them, staying byte-for-byte identical to the previous
  output while keeping every intermediate array small (CRuby, whose arrays are
  unbounded, never hit this, so `scripts/rpgxp_testbed_check.rb` had not caught
  it). Verified by booting the packed *Pray for You* project (222 archived
  entries, no loose `Data/`).
