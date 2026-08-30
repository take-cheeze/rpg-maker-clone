- **A Conditional Branch of an unrecognized type now takes the else branch,
  instead of always taking the true one.** Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: an unhandled condition type (RPG Maker 2003 v1.11's own
  "EX conditions" — savestate available, Test Play, ATB-wait, fullscreen —
  or a Maniac Patch type) defaults to false. This build defaulted such a
  branch to true, so any project using one of these newer condition types
  always ran the wrong branch — most seriously, a debug/cheat-content gate
  meant to hide under normal play would instead always show.
