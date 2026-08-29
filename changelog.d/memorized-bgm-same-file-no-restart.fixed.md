- **Play Memorized BGM no longer restarts a track that was never actually
  stopped.** `Game::Interpreter#do_play_memorized_bgm` called
  `RGSS::Audio.bgm_play` unconditionally, so restoring a memorized BGM that
  happened to share its filename with whatever was still currently playing
  (e.g. Memorize BGM taken with nothing else played afterward, or a
  duck-and-return to the same track) wrongly broke and restarted it from
  the top. Verified against a reference implementation's own memorized-BGM
  playback path, not independently confirmed against genuine RPG_RT under
  wine: a bare call to the same BGM-play routine every other BGM entry point
  goes through, same-file
  skip included — not a lower-level call that bypasses it. Fixed with the
  identical same-file idiom `Game::Interpreter#play_audio`'s `:bgm` branch
  already uses. Covered by a new `scripts/rpg2k_logic_check.rb` check,
  confirmed to fail against the pre-fix code before the fix.
