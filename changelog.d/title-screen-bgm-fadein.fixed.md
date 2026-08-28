- **The title screen's own database BGM (`System > title music`) now honours
  its `fade_in` field instead of silently dropping it.** Cycle #202/#203
  wired the same `fade_in` field (liblcf `BGM`-struct field 2,
  `mruby-lcf/mrblib/schema.rb`) through to `RGSS::Audio.bgm_play`'s 5th
  argument for Play BGM, Play Memorized BGM and the battle/inn/vehicle/
  game-over BGM helpers, but `Scene::Title#play_title_bgm` was never
  touched — it still called `Audio.bgm_play` with only 3 arguments,
  and its own doc comment claimed the audio backend "can fade a BGM out,
  not in", a stale statement written before that same cycle #202 gave
  `Mix_FadeInMusic` a real `fadein_ms` path (`src/sdl_audio.cxx`). Fixed by
  threading `bgm.fade_in || 0` through the same 5-argument
  `Audio.bgm_play` call every sibling BGM source already uses, and
  correcting the doc comment.
