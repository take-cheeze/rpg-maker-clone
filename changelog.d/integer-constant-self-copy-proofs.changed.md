- **bc2cpp**: a declared `X: Integer` constant now proves (INTEGER_CONSTANT_PROOF)
  when another same-named constant only aliases it (`ARROW_W = Window::ARROW_W`,
  SELF_COPY in `tools/bc2cpp/declared_constants.rb`). The `Game::Character`
  turn tables are now `TURN_RIGHT_DIR`/`TURN_LEFT_DIR`/`TURN_180_DIR` and the
  map/chipset editors' white `TEXT_COLOR` is `FONT_COLOR`, so the Integer
  `MoveRoute::TURN_*` and menu `TEXT_COLOR` constants prove too; 14 of the 17
  TC1011 "no fact" notes are gone.
