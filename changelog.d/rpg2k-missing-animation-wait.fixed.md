- **A Show Battle Animation command naming an animation with nothing
  drawable now waits the real, data-driven duration RPG_RT actually applies,
  instead of a fixed guessed-at delay.** Confirmed against EasyRPG Player's
  source (`Game_Screen::ShowBattleAnimation`, `BattleAnimation`): there is no
  fixed fallback wait anywhere in the reference implementation. An invalid
  animation id, or a database row with no frames at all, now waits exactly 0
  ticks — matching `Game_Interpreter`'s own zero-wait fallthrough, with no
  one-frame floor. A row with real frame data but an unloadable
  `Battle/<name>` graphic sheet still waits that row's own real duration
  (`frames.size * 2` ticks), since EasyRPG computes the frame count from the
  database row before it ever attempts the graphic load — a missing sheet
  changes only what (nothing) actually draws, not the timing.
