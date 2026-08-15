- **The battle victory jingle now plays as a real one-shot "ME" that the
  field BGM resumes after**, instead of looping as an ordinary BGM that got
  cut off the instant the result screen was dismissed. `Scene::Map#play_victory_bgm`
  now calls `RGSS::Audio.me_play` — the same native music-effect primitive
  (`src/sdl_audio.cxx`'s `me_play`/`me_stop`, which auto-pauses the BGM
  channel while the effect plays and auto-resumes it once the effect ends)
  `mruby-rpgvx`'s `RPG::ME#play` already forwards to — instead of the
  ordinary looping `#play_bgm`, and `#restore_pre_battle_bgm` calls
  `RGSS::Audio.me_stop` before restarting the pre-battle field/vehicle
  track, ending the fanfare through its own stop path rather than a bare
  BGM play yanking the shared music stream out from under it. Covered by
  updated `scripts/rpg2k_scene_check.rb` checks, confirmed to fail against
  the pre-fix code before the fix.
