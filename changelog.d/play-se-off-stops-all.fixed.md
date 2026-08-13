- **Play Sound Effect's "(OFF)" choice now stops every currently-playing SE**,
  instead of silently doing nothing. `Game::Interpreter#play_audio`
  (`mruby-rpg2k/mrblib/interpreter.rb`) returned immediately on a blank
  filename for both Play BGM and Play SE alike; SE is truly polyphonic
  (unlike the single-channel BGM slot), so real RPG_RT's "(OFF)" selection —
  encoded the same way, as an empty filename — halts every in-flight sound
  effect at once rather than leaving a "current" one alone the way a blank
  Play BGM does (yado.tk). `RGSS::Audio.se_stop` is now called on that blank
  branch when the command is a Play SE; Play BGM's own blank-name case is
  untouched. Covered by two new `scripts/rpg2k_logic_check.rb` checks (a
  blank-name Play SE reaches the stop-all backend call and plays nothing; an
  ordinary named Play SE still plays normally), confirmed to fail against the
  pre-fix code before the fix.
