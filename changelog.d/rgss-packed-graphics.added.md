- **A packed RPG Maker release finds its graphics.** A released XP / VX / VX Ace
  game ships one encrypted `Game.rgssad` / `.rgss2a` / `.rgss3a` holding its whole
  tree — `Data/` *and* `Graphics/` and `Audio/` — with nothing loose on disk. The
  data layer has read `Data/` out of it for a while, but the native asset loaders
  only ever opened files, so a packed game booted with no art at all: every
  `Cache.*` call in a game's own scripts is a `Bitmap.new("Graphics/…")`.
  - The awkward part was never the decrypting (`RPGXP::RGSSAD` already did that)
    but the plumbing: an asset is asked for by name from deep inside a bundle,
    with no handle to thread down. So each maker's boot shell registers its
    opened archive once as `RGSS.asset_archive`, and `Bitmap#initialize` consults
    it after the loose-file search misses, trying the same extension candidates
    (`.png`, `.jpg`, `.jpeg`, `.xyz`, `.bmp`). Loose files still shadow packed
    ones, which is what RGSS itself does.
  - The decoding is deliberately unchanged: `Bitmap#_init_file` and the new
    `#_init_memory` share one `bmp_decode_into`, so a packed asset goes through
    the same stb / XYZ / tolerant-PNG chain a loose one does. Those fallbacks are
    exactly what a real RPG Maker project needs (indexed XYZ windowskins,
    windowskin PNGs whose deflate stream strict inflaters reject), and the packed
    path must not quietly lack them.
  - A broken archive is a miss, not a crash: the read failure is reported to
    `$stderr` and `Bitmap.new` still raises its own diagnostic naming the asset.
  - `scripts/rgssad_asset_check.bash` (new, in CI) checks it end to end in the
    real binary: the XP test bed is packed twice, differing only in whether its
    title graphic is inside `Game.rgssad`, and the engine must find it in the
    first run and report the miss in the second. The A/B is the point — a single
    run would pass just as well if the archive were never consulted. Both
    test-bed checks now pack a graphic alongside the data too, and the VX one
    asserts that booting a packed project registers its archive at all.

  Audio is not covered yet: `RGSS::Audio` plays through a C function table
  (`include/rgss_audio.hxx`) whose entry points all take a path, so a packed BGM
  needs that interface to grow memory variants. A packed game boots and draws,
  but stays silent.
