- **The victory fanfare now honours a configured BGM fade-in instead of
  silently dropping it.** Cycle #203 wired battle/inn/vehicle-boarding/
  Game-Over BGM fade-ins through to `RGSS::Audio.bgm_play`, but deliberately
  left `Scene::Map#victory_bgm`/`#play_victory_bgm` alone: the victory
  fanfare plays through `RGSS::Audio.me_play`, RPG_RT's distinct one-shot
  "ME" channel, whose native signature (`sdl_audio.cxx`,
  `include/rgss_audio.hxx`, `mruby-rgss/src/audio.cxx`,
  `mruby-rgss/mrblib/lib.rb`) had no fadein parameter at all -- unlike
  `bgm_play`, it was never given one. This cycle extends the native ME
  playback path the same way `bgm_play`'s was extended in cycle #202:
  `RgssAudioBackend::me_play`/`me_play_mem` each grew a trailing `fadein_ms`
  parameter, `sdl_audio.cxx`'s implementations forward it to the same
  `play_music`/`play_music_mem` helpers `bgm_play` already uses (which
  already supported `fadein_ms` for any loop count, ME's "play once" `1`
  included -- `Mix_FadeInMusic` works identically for a one-shot ME as for a
  looping BGM, since both are the same underlying `Mix_Music` stream), and
  `RGSS::Audio.me_play`/`_me_play_mem` grew a matching optional 4th/5th
  argument. `Scene::Map#victory_bgm` now reads `fade_in`/`fadein` off both
  the database's `battle_end_music` and a Change System BGM victory-slot
  override the same way `#battle_bgm`/`#inn_bgm` already do, and
  `#play_victory_bgm` forwards it as `RGSS::Audio.me_play`'s new 4th
  argument, `|| 0` defaulted the same way volume/tempo already are.
