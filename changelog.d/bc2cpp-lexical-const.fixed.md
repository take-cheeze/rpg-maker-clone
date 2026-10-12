- **bc2cpp** resolves a constant read through its lexical scope (ADR 0421): a read of `TURN_LEFT` inside `Game::Character`
  no longer shares a class set with `Game::MoveRoute::TURN_LEFT`, and a read that cannot be resolved soundly is refused
  rather than given a joined class. `BC2CPP_LEXICAL_CONST=0` restores the bare-name model.
