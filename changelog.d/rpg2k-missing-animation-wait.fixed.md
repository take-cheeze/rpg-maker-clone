- **A Show Battle Animation command naming an animation with nothing
  drawable now waits the real, data-driven duration RPG_RT actually applies,
  instead of a fixed guessed-at delay.** Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: there is no fixed fallback wait anywhere in it. An invalid
  animation id, or a database row with no frames at all, now waits exactly 0
  ticks — matching the same reference implementation's own zero-wait fallthrough, with no
  one-frame floor. A row with real frame data but an unloadable
  `Battle/<name>` graphic sheet still waits that row's own real duration
  (`frames.size * 2` ticks), since a reference implementation computes the
  frame count from the database row before it ever attempts the graphic
  load — a missing sheet changes only what (nothing) actually draws, not
  the timing.
