- **A Common Event or Map Event Parallel Process genuinely mid a waiting Key
  Input Proc (11610) now survives a genuine `.lsd` Save/Continue**, instead
  of silently resuming past the wait with the requested variable stuck at 0.
  Follow-up to cycle #193's own investigation, which found this is the one
  wait kind a Parallel Process can be saved mid — every other Show
  Message/Choices/Input Number wait is unreachable for a save at all, since
  they all set the same scene-wide state that blocks the Save menu
  regardless of which interpreter raised them, but `#event_busy?` never
  inspects a Parallel Process's own wait state. `Game::Interpreter
  #call_stack_snapshot` now rewinds this one specific wait kind's own
  `current_command` by one, so `#restore_call_stack` naturally re-executes
  the Key Input Proc command from scratch on the next tick — a pure
  function of its own parameters, and exactly what genuine RPG_RT itself
  already does every frame it re-checks a still-pending one. Covered by a
  new check in `scripts/rpg2k_logic_check.rb`.
