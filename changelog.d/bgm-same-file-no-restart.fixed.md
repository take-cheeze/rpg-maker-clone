- **Re-triggering Play BGM with the file already playing no longer restarts
  it from the top.** `Game::Interpreter#play_audio`'s `:bgm` branch now
  compares the command's filename against `@state.current_bgm` and skips
  the redundant `RGSS::Audio.bgm_play` call (and the loop-tracking reset)
  when the same file is already current, matching yado.tk's single-BGM-
  channel finding. The state still records the command's latest
  vol/tempo so Memorize BGM keeps stashing the most recently requested
  settings. The other half of the finding — applying the new vol/tempo/pan
  to the still-playing track in place — remains unaddressed: this build's
  `RGSS::Audio` has no primitive to adjust an already-playing BGM without
  restarting it (`bgm_play` is the only vol/pitch entry point and it always
  restarts via SDL_mixer), so it is left documented as blocked in
  `docs/TODO.md` rather than faked.
