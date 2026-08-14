- **Play BGM's balance (pan) parameter is now wired through to playback.**
  `Game::Interpreter#play_audio`'s `:bgm` branch used to read only
  `cmd.param(1)`/`cmd.param(2)` (volume/tempo) and leave `cmd.param(3)`
  (balance) on the floor — pan was never a Play BGM parameter at all before
  this. SDL_mixer has no per-`Mix_Music` panning API, but
  `Mix_SetPanning(MIX_CHANNEL_POST, left, right)` registers a postmix effect
  on the final mixed stream, which is the one documented way to reach a
  playing music track at all (at the cost of also panning BGS/SE, since they
  land in the same final mix). Added a `bgm_pan` entry point
  (`include/rgss_audio.hxx`, `src/sdl_audio.cxx`, `mruby-rgss`'s
  `_bgm_pan`/`RGSS::Audio.bgm_pan`), mirroring `bgm_volume`'s existing shape,
  and wired it into `play_audio` on RPG2000's own Play BGM balance scale (0
  full left, 50 centre, 100 full right), re-applied on every Play BGM
  regardless of the same-file-no-restart branch since panning has no
  per-track state to restart.
