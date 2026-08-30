- **A second, distinct Auto-Start map/common event now starts the same frame
  the first one finishes with no Wait, instead of waiting for the next real
  frame.** Ported from a reference implementation's foreground-event driver
  rather than guessed at, not independently confirmed against genuine
  RPG_RT under wine: it drives
  the single shared foreground interpreter inside a loop that keeps going
  while it is still running and has not hit its own loop limit — the instant a
  pushed event's own command list empties out, that same real-frame call
  immediately rescans every event's own waiting-for-foreground-execution flag and
  pushes another eligible one too. `Scene::Map#update`
  (`mruby-rpg2k/mrblib/scene/map.rb`) used to call `#start_autostart` exactly
  once per real frame, so a second, not-yet-run Auto-Start event on the same
  map had to wait for the *next* real frame even when the first one's own
  script ended with no Wait at all. Fixed with a new
  `Scene::Map#drive_autostart_cascade`, which keeps calling `#start_autostart`
  for a fresh candidate every time the interpreter genuinely goes idle again
  within the same `#update` call, stopping the moment nothing new starts or
  the interpreter is left busy (mid-script, or parked on a Wait/Show
  Text/etc.) for a future frame. Each distinct event id can still only ever be
  picked up once per visit, unchanged — this fix only closes the *cross-event*
  cascading gap, not whether the very same event's own script restarts from
  the top on its own natural end (a much larger, deliberately unaddressed
  question, see `docs/TODO.md`'s "Autorun (auto-start) events run at most
  once per map visit" bullet). Covered by three new
  `scripts/rpg2k_scene_check.rb` checks, two confirmed to fail against the
  pre-fix code before the fix.
