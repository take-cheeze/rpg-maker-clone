- **The victory fanfare now honours a configured pan (balance) instead of
  silently dropping it.** Cycle #219 wired the `BGM` struct's field 5
  (`balance`, `mruby-lcf/mrblib/schema.rb`) through to `RGSS::Audio.bgm_pan`
  for `#battle_bgm`/`#inn_bgm`/`#vehicle_bgm`/`#play_map_bgm` and
  `Scene::GameOver`, but deliberately left `Scene::Map#play_victory_bgm`
  alone: its own doc comment at the time assumed closing the gap there would
  need a new, unverified native signature change to `RGSS::Audio.me_play`
  the way the fanfare's fade-in genuinely needed one (cycle #204, since
  `Mix_FadeInMusic` only applies at the moment a track starts). That
  assumption does not hold for panning -- `RGSS::Audio.bgm_pan` is a live
  call with no dependency on which helper started the track (its own doc
  comment already documents "re-applies unconditionally, same-file-or-not"),
  and `#me_play`'s own doc comment already establishes the one-shot ME
  fanfare shares the ordinary BGM channel's single underlying `Mix_Music`
  stream, exactly what `bgm_pan`'s `Mix_SetPanning(MIX_CHANNEL_POST, ...)`
  re-pans. So `#victory_bgm` now reads `balance:` off a Change System BGM
  (10660) victory-slot override and the database's own `battle_end_music`
  the same way it already reads `fadein`, and `#play_victory_bgm` calls the
  already-existing `RGSS::Audio.bgm_pan(music[:balance] || 50)` right after
  `me_play` starts the fanfare -- the same mechanical plumbing cycle #219
  did for its own five call sites, no native code touched at all. Without
  this, the fanfare played back panned to whatever `bgm_pan` value the
  *battle* track had last set (stale), never its own configured balance.
