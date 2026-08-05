- `scripts/analyze_game.rb`'s move-route name table was shifted from id 23
  onward, so the move-command histogram mislabelled most of what it reported:
  it had 23 `SwitchOn`, 31 `Through(on)`, 35 `ChangeGraphic`, 37 `Wait` and
  40 `LockFacing`, where liblcf's `MoveCommand::Code` — and the runtime's own
  `Game::MoveRoute` / `Game::Interpreter::MoveCmd` constants, which real move
  routes are actually decoded with — have 23 `Wait`, 26 `LockFacing`,
  32 `SwitchOn`, 34 `ChangeGraphic` and 36 `Through(on)`. Nine of a real game's
  twelve most-used move commands were reported under the wrong name (5148 `Wait`
  steps appeared as `SwitchOn`). The runtime was never affected — this was a
  reporting bug only, the same shape as the 106xx event-opcode shift fixed
  earlier in the same file.
