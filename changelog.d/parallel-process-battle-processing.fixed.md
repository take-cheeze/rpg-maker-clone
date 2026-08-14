- **A Parallel Process's own Battle Processing (Enemy Encounter) command now
  actually opens and drives a real fight,** instead of being silently
  skipped outright. `Scene::Map#drive_parallel_wait` had cases for every
  other wait kind reachable from a Parallel Process (`:wait`, `:key_input`,
  `:animation`, `:game_over`, `:movement`, `:teleport`, `:message`,
  `:choice`, `:number`, `:screen`, `:picture`, `:sprite_flash`) but none for
  `:battle`, so it fell into the generic "background: ignore ... requests"
  branch and resumed the interpreter unconditionally the next frame — no
  battle screen ever opened, and the process fell straight through into its
  own `[Victory]` handler marker as though the encounter had never run, a
  real gap for the ordinary "a Common Event's Parallel Process polls a
  switch/variable and starts a scripted or wandering-style fight" pattern.
  `#drive_battle`/`#open_battle`/`#finish_battle` now take the raising
  interpreter explicitly and `@battle_ui` records its own `owner`, so a
  battle page's Call Common Event resolves against the right interpreter and
  the outcome resumes it, not always the foreground. A new
  `#step_battle_owner_parallel` keeps the fight's own owning Parallel
  Process advancing every frame even though `@battle_ui`'s presence pauses
  every *other* parallel process for the fight's duration, and
  `#event_busy?`/`#drive_event` now also freeze ordinary player movement and
  an unrelated foreground script while a Parallel-Process-opened fight is on
  screen, matching a foreground-opened one. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks, both confirmed to fail against the
  pre-fix code before the fix.
