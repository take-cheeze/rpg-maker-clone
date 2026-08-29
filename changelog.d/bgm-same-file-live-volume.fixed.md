- **A same-file Play BGM (or a battle/vehicle/inn/map BGM, or a Play
  Memorized BGM, matching the already-playing track) now re-applies its own
  volume live instead of leaving the previous volume in place.** RPG_RT's
  single native BGM entry point, ported from a reference implementation's
  own BGM-play code and not independently confirmed against genuine
  RPG_RT under wine, does not restart a
  track that names the file already playing, but it does "adjust volume and
  speed" on it — this codebase's existing same-file no-restart logic
  (`Game::Interpreter#play_audio`, `Scene::Map#play_bgm`,
  `Game::Interpreter#do_play_memorized_bgm`) previously did neither, since
  `RGSS::Audio` had no primitive for adjusting a playing track in place.
  Added a new `bgm_volume` backend entry point (`include/rgss_audio.hxx`,
  `src/sdl_audio.cxx`'s `Mix_VolumeMusic` call, `mruby-rgss`'s
  `_bgm_volume`/`bgm_volume`) and wired all three same-file call sites
  through it. Tempo/pan remain unaddressed: SDL_mixer cannot re-pitch a
  playing music stream, and pan was never wired as a Play BGM parameter at
  all.
