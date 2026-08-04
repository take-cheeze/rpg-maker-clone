- MV audio smoke test + authored sample sound: the committed MV sample now
  ships a tiny hand-encoded `audio/se/Beep.wav` (a short sine beep, no
  copyrighted RTP), wired to the sample's Cursor/OK/Cancel/Buzzer system sounds
  so interactions actually play through the audio bridge. A new `--mv_audio_test`
  flag drives it: once on the map it plays the SE through MV's `AudioManager`
  (our bridge enqueues a plain-text op), drains what the live engine queued,
  parses and dispatches it through the same path `pump_audio` uses, and confirms
  the asset resolves — logging `[MV-AUDIO] op=.. dispatched=.. asset=..`. This
  exercises the full audio path (engine → `__mv_audioQueue` → drain →
  `RGSS::Audio`) end to end, which the empty-audio test beds never did. Wired as
  a non-blocking `build` job step alongside the other MV smokes.
