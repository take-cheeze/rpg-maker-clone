- The RPG Maker MV/MZ move probe (`--mv_move_test` / `--mz_move_test`) now
  waits out a running map event, not just an open message window, before it
  starts holding a direction, and its `[MV-MOVE]`/`[MZ-MOVE] end` line now
  reports a `blocked=` field alongside `moved=`. Previously the probe's
  settle window only checked `$gameMessage.isBusy()`, so an opening cutscene
  that never shows text -- Show Picture, Wait, Set Move Route, Fadeout/Fadein,
  Tint Screen and the like, chained straight from the autorun event that
  starts the instant the map loads -- swallowed every held-direction input
  frame and the probe reported a bare `moved=false`, indistinguishable from a
  genuine movement bug. `MV.event_running?` (`$gameMap.isEventRunning()`)
  closes that gap: the settle window now waits on either check, capped by the
  same `MOVE_SETTLE_MAX_FRAMES` as before, and `blocked=true` on the end line
  says plainly "the game's own event was still running when the probe gave
  up" rather than making every caller re-derive that by hand. Found probing a
  real, large freeware MV release whose opening cutscene runs entirely
  through picture/wait event commands with no message window at all.
