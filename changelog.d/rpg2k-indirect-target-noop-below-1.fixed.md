- RPG Maker 2000: **Control Variables** / **Control Switches** indirect
  ("pointer") *target* addressing now no-ops when the resolved switch/
  variable id is 0 or negative, instead of writing to that bogus slot.
  `Game::Interpreter#range`'s indirect branch had no bounds check at all,
  so a command addressed through a pointer variable holding 0 or a
  negative number wrote to that id rather than doing nothing, the way
  RPG_RT's target-role indirect addressing does (the operand-role read
  side already handled this correctly via each store's own missing-key
  default). Covered by a new `scripts/rpg2k_logic_check.rb` check.
