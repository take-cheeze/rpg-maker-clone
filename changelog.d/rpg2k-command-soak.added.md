- **`scripts/rpg2k_command_soak.rb`** runs every event command of every
  downloaded test-bed through `Game::Interpreter` and fails if any of them
  raises, or if any of them reaches a handler's "I do not know this" arm — the
  `[RPG2k]` lines the runtime reports rather than swallowing. The unit checks pin
  the semantics against hand-written commands; this covers the parameter shapes
  real games actually ship, at a scale nobody writes fixtures for (371,762
  commands across the two Nepheshel builds and the RPG2003 test-bed). Each
  command runs in isolation against a fresh state, so one command's wait or
  teleport cannot mask the rest of its list. Wired into CI beside the LCF
  test-bed check, after the download step.
