- **RGSS3 `Audio.bgm_play`'s `pos` argument** (mid-track resume) now actually
  seeks instead of always playing a BGM from the beginning. Wired through
  `Mix_SetMusicPosition` on both the loose-file and packed-archive playback
  paths — the archive path is what a released game's resume actually reaches,
  since its whole `Audio/` tree is packed into one encrypted archive. `pos` is
  milliseconds, matching `Audio.bgm_pos`'s own return value, so
  `Audio.bgm_play(f, v, p, Audio.bgm_pos)` round-trips exactly. A decoder that
  cannot seek still plays from the track's own beginning rather than not
  playing at all.
