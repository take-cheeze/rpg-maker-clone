- **A Parallel Process's own Show Text/Show Choices now actually opens the
  shared message window, instead of being silently dropped.**
  `Scene::Map#drive_parallel_wait` had cases for every other wait kind a
  background process could park on (`:wait`, `:key_input`, `:animation`,
  `:game_over`, `:movement`, `:teleport`, `:screen`, `:picture`,
  `:sprite_flash`) but none for `:message`/`:choice`, so a Common Event or
  map event Parallel Process's own Show Text fell into the generic
  "background: ignore message/choice requests" branch and the interpreter
  sailed straight past it — the window never appeared, and the next command
  ran as if it had been a no-op. Fixed by generalizing `#open_message` to
  track which interpreter opened the current window (`interp:`, defaulting
  to the foreground `@interpreter`) and threading that through
  `#drive_message`/`#drive_text_message` in place of a hardcoded
  `@interpreter`, then adding `:message`/`:choice` cases to
  `#drive_parallel_wait` that open the shared window only while it is free
  and otherwise leave the requesting process parked to retry next frame —
  matching "two message windows can never be shown simultaneously," which
  this codebase's single `@message` slot already enforced for the
  foreground but never extended to a background process. Input Number from
  a Parallel Process is a separate, narrower gap left open. Covered by three
  new `scripts/rpg2k_scene_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
