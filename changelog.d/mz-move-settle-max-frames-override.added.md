- **`scripts/mz_boot_check.bash`'s `play` mode can now be pushed past a real
  game's whole scripted opening, via a new `MZ_MOVE_SETTLE_MAX_FRAMES`
  override.** The move probe's settle window (`mruby-mvjs/mrblib/mv.rb`'s
  `MOVE_SETTLE_MAX_FRAMES`, 180) is only a safety cap for an ordinary game's
  opening dialogue, not a bound on a whole intro — driving the real downloaded
  `data/EgoicAnswers` release through the check found its own opening runs
  650+ frames of blocking waits alone (plus ~49 message boxes and a forced
  battle) before the player ever gets a turn, well past that cap, so the probe
  reported `blocked=true` instead of `moved=true` even though nothing was
  actually broken. Rather than raise the shared default — which would make
  every other check's safety cap that much slower to catch a genuinely-stuck
  probe — a new `--move_settle_max_frames` launcher flag (0 leaves the
  180-frame default alone) is threaded through by a `MZ_MOVE_SETTLE_MAX_FRAMES`
  env var, the same way `MZ_TROOP`/`MZ_MODE` already work. Unset behaviour is
  unchanged (`data/mz-sample` still settles in well under 180 frames); against
  `data/EgoicAnswers`, `MZ_MOVE_SETTLE_MAX_FRAMES=8000` gets the probe all the
  way through the intro into `Scene_Battle`.
