- **A "Message Options" command's "move other events during message" flag
  (LCF field 44, `message_continue_events`) now actually does something.**
  `Game::MessageConfig#continue_events` was already parsed from the database/
  save and settable via the Message Options event command, but
  `Scene::Map` never once read it: `#step_events` (autonomous move types and
  forced/custom routes for every non-parallel map event) was only ever
  called from the branch of `#update` that runs when nothing is busy, so a
  bystander event held perfectly still for the whole time any message window
  or choice list stayed open, whether or not the game had turned this flag
  on — matching yado.tk's default ("Autorun blocks other events too") but
  never its documented exception ("unless 'move other events during message
  wait' is on"). Fixed by calling `#step_events(allow_trigger: false)` a
  second way, from inside the busy branch, whenever
  `#events_move_during_message?` (a message window is open **and**
  `continue_events` is set) — scoped to message windows specifically, not
  `#event_busy?` in general, so an Autorun grinding through non-blocking
  commands with no message shown still freezes the map either way.
  `allow_trigger: false` (threaded through `#step_event`/`#move_autonomous`)
  still lets a bystander walk, turn and finish its route, but never lets one
  start a **new** event over the player: there is only one foreground
  `@interpreter`, already busy with the open message, and RPG2000 never
  shows two message windows at once — an event-touch (trigger 2) bystander
  that reaches the player's tile during this window still stops adjacent to
  it, exactly like the ordinary (nothing-else-running) case, just without
  starting its own commands. Covered by three new
  `scripts/rpg2k_scene_check.rb` checks (a bystander holds still while a
  message stays open with the flag off, the existing/default case; a
  bystander keeps walking with the flag on; an approaching trigger-2
  bystander still never starts its own event while the flag is on), two
  confirmed to fail against the pre-fix code before the fix.
