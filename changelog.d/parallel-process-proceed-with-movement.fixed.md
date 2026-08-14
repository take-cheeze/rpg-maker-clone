- **A Parallel Process's own "Proceed With Movement" (wait for completion on
  a forced move route) now actually blocks that process.** `Scene::Map#
  drive_parallel_wait` had no `:movement` case in its wait-kind dispatch —
  only the foreground's own `#drive_event` did — so a Common Event or Map
  Event Parallel Process issuing the identical command fell into the generic
  "background: ignore message/choice/teleport requests" resume branch and
  read it as a fire-and-forget no-op regardless of "wait for completion",
  including the documented permanently-impassable/hidden-target freeze. Fixed
  by adding a `:movement` case that resumes only once `#forced_movement_done?`
  reports every targeted route finished, the same predicate the foreground
  path already relies on. Covered by a new `scripts/rpg2k_scene_check.rb`
  check, confirmed to fail against the pre-fix code before the fix.
