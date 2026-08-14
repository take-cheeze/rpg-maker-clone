- **A Battle "Lose: Branch" handler's own recovery (a Change HP/Full Recovery
  right after the encounter) no longer loses a race to a Parallel Process's
  own Game Over check.** `Scene::Map#finish_battle` clears `@battle_ui`
  (unpausing every Parallel Process) and calls `Game::Interpreter#resume_battle`
  before `Scene::Map#update`'s own `#step_parallels` gets another chance to
  run — but `#resume_battle` only flipped the interpreter off its `:battle`
  wait; nothing then drove it into the handler's own recovery commands until
  the *next* frame's ordinary "not waiting" path happened to reach it. That
  left a full frame — party still at 0 HP, `@battle_ui` already `nil` — for
  a Parallel Process to notice the wipe (via any command that calls
  `#check_game_over`: Change HP/MP, Change Condition, Full Recovery, ...) and
  raise Game Over first, before the Lose branch's own recovery ever ran.
  Fixed by driving the interpreter one step further immediately once it comes
  off the `:battle` wait — `Scene::Map#drive_event`'s `when :battle` case now
  drains its own step budget the same frame, the same "Wait 0.0 sec costs one
  frame, not two" idiom the `when :wait` case already uses — so a Lose branch
  with no Wait/Show Text ahead of its own recovery reaches it before this
  same frame ends, well before the next frame's Parallel Process window ever
  opens. Covered by a new `scripts/rpg2k_scene_check.rb` check, confirmed to
  fail against the pre-fix code.
