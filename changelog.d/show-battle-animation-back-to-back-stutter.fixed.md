- **Chaining two Show Battle Animation (11210) calls back-to-back — waiting
  for the first, then immediately issuing another — no longer loses an extra
  real frame between them.** Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine: its own
  interpreter-update loop's only wait-time check is `if
  (wait_time > 0) { wait_time--; break; }` — it stops
  processing for the frame *only while* the countdown is still above zero, so
  the exact real frame a waited-for animation's own duration reaches 0 falls
  straight through into whatever command follows instead of costing a
  further frame, the same "spend this frame's own step budget immediately"
  rule already ported here for Wait 0.0s and the Battle "Lose: Branch" race.
  `Scene::Map#drive_event`'s `:animation` case used to just call
  `#drive_map_animation` and stop, unlike the `:wait`/`:battle` cases beside
  it in the same dispatch — so a command chained right after a finished Show
  Battle Animation always ran one real frame later than real RPG_RT. Fixed
  for both the foreground interpreter (`#drive_event`) and a Common Event
  Parallel Process's own chained calls (`#step_parallel`'s wait-kind
  dispatch, which previously gave this same-frame treatment only to
  `:wait`). A separate, structural one-frame startup latency this codebase's
  request/dispatch split still has for *any* Show Battle Animation (not
  specific to chaining) remains open. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks, both confirmed to fail against the
  pre-fix code before the fix.
