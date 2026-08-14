- **A Parallel Process's own screen-effect, Move Picture, or Flash Sprite
  command now actually blocks that process when its wait flag is set,**
  instead of reading as a fire-and-forget no-op. `Scene::Map#
  drive_parallel_wait` had no case for the `:screen` (Erase/Show/Tint/Flash/
  Pan/Shake Screen), `:picture` (Move Picture), or `:sprite_flash` (Flash
  Sprite) wait kinds — only the foreground's own `#drive_event` did — so a
  Common Event or Map Event Parallel Process issuing any of these commands
  with "wait for completion" set fell into the generic "background: ignore
  message/choice requests" resume branch and resumed on the very next tick
  regardless; the effect itself already ran (`#apply_interpreter_requests`
  applies a parallel process's own requests too), only the wait never held
  the process up. Fixed by adding the same three predicate checks
  `#drive_event`'s own dispatch already uses (`@state.screen.busy?`,
  `@state.pictures_moving?`, `sprite_flashing?`) to `#drive_parallel_wait`.
  Covered by three new `scripts/rpg2k_scene_check.rb` checks, all three
  confirmed to fail against the pre-fix code before the fix.
