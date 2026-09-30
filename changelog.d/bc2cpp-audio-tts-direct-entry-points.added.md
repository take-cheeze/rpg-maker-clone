- **RGSS:** the `RGSS::Audio` primitives (`_bgm_volume`, `_bgm_pan`, `_bgm_fade`,
  `_bgm_stop`, `_bgm_pos`, `_bgs_*`, `_me_*`, `_se_stop`, `_update`,
  `_midi_available`, `_can_play_mem?`) and `RGSS::Tts` got frame-independent
  `rgss::*_direct` entry points from `scripts/native_binding_split.rb`, which now
  attributes a module handed to a `rgss_*_define` function in another source file
  and writes its generated block into `audio.cxx`/`tts.cxx`.
