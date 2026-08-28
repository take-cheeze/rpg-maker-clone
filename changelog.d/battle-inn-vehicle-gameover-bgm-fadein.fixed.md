- **Battle, Show Inn, boarding a vehicle, and the Game Over screen now honour
  a configured BGM fade-in instead of silently dropping it.** Cycle #202
  wired Play BGM's own fade-in parameter through to `RGSS::Audio.bgm_play`'s
  new 5th `fadein` argument, but `Scene::Map#battle_bgm`/`#inn_bgm`/
  `#vehicle_bgm` and `Scene::GameOver#play_gameover_bgm` never picked it up:
  each resolves a Music/BGM struct down to a `{ name:, volume:, tempo: }`
  hash and calls `#play_bgm` (`RGSS::Audio.bgm_play` underneath) without ever
  reading `fade_in` off it, for both of that struct's two real sources --
  the database's own `battle_music`/`inn_music`/`boat_music`/`ship_music`/
  `airship_music`/`gameover_music` (each a liblcf `BGM`-struct instance,
  field 2), and a Change System BGM (10660) override for that slot (which
  already carries its own `fadein:` reread off the command's param 1,
  `do_change_system_bgm`). Both sources now flow through to `#play_bgm`'s
  `RGSS::Audio.bgm_play` call, the same 5-argument idiom Play BGM and Play
  Memorized BGM already use, `|| 0` defaulted the same way volume/tempo
  already are. The victory fanfare (`#victory_bgm`/`#play_victory_bgm`) is
  deliberately left alone: it plays through `RGSS::Audio.me_play`, RPG_RT's
  distinct one-shot "ME" channel, which has no fadein parameter at all in
  this engine's audio layer (unlike `bgm_play`) -- wiring it would mean
  extending the native ME playback path (`sdl_audio.cxx` and friends), out of
  scope for a fix that only forwards an already-plumbed value through mrblib
  call sites.
