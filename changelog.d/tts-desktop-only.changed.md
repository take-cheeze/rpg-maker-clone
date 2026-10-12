- **`RGSS::Tts` (Zundamon narration, ADR 0046) now exists only in the desktop
  build, the only one that can back it.** The Wio Terminal, Maix, PSP,
  Emscripten and Android builds no longer register the three native methods
  (an empty `tts_off.cxx` replaces `tts.cxx`) and ship an empty
  `Scene::Map#speak_message` (`mrblib_limited/map_tts_off.rb`) in place of the
  one that asks `RGSS::Tts.available?`, so no Ruby there names `RGSS::Tts`.
  `--zundamon_tts`, the VOICEVOX backend and the desktop behaviour are
  unchanged. The bc2cpp closed-world source sets follow the same split, and
  `scripts/tts_limited_check.rb` pins it (ADR 0417).
