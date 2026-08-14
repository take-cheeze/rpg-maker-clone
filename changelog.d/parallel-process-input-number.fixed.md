- **A Parallel Process's own Input Number command now actually opens the
  shared digit-entry widget**, both the standalone panel and the
  merged-onto-a-preceding-Show-Text shape, instead of being silently
  dropped. `Scene::Map#drive_parallel_wait` had cases for `:message`/
  `:choice` (see "A Parallel Process's own Show Text/Show Choices now
  actually opens the shared message window") but none for `:number`, so a
  Common Event or map event Parallel Process's own Input Number fell into
  the generic "background: ignore..." branch and the interpreter sailed
  straight past it — the widget never appeared, and the next command ran
  as if it had been a no-op. Fixed by adding an `interp:` keyword to
  `#open_number_input` (mirroring `#open_message`'s own, defaulting to the
  foreground `@interpreter`), threading it through `#drive_number_input`'s
  confirm handler in place of a hardcoded `@interpreter`, and adding a
  `:number` case to `#drive_parallel_wait` that opens the widget for a
  fresh request (`@message.nil?`) or the requesting process's own already-
  open message (`@message[:interp].equal?(it)`, the merged shape) and
  otherwise leaves it parked to retry next frame — the `:choice` case
  above gained the identical `@message[:interp].equal?(it)` widening for
  its own merged shape, which was equally unreachable before this fix.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks (a Common
  Event's standalone Input Number opens its own compact panel and blocks
  the process until confirmed; a map event's Show Text immediately
  followed by Input Number merges into the same still-open window),
  confirmed to fail against the pre-fix code before the fix.
