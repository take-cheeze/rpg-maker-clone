- **bc2cpp**: a declared `X: Integer` constant now proves (INTEGER_CONSTANT_PROOF)
  for the reads that resolve to its definition, the way the runtime looks
  constants up (LEXICAL_CONST), even when a same-named constant elsewhere holds
  another value (the Integer `MoveRoute::TURN_*` beside the `Game::Character`
  turn tables, the menus' `TEXT_COLOR` beside the editors' white one). A
  same-named constant that only aliases it (`ARROW_W = Window::ARROW_W`,
  SELF_COPY) no longer withholds the bare-name fact either.
