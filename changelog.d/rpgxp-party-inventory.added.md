- RPG Maker **XP** party inventory and item event commands. `RPGXP::Game::State`
  now carries `$game_party`-style item / weapon / armor stores (id → count, each
  clamped to 0..99 and persisted in the portable save), and the interpreter runs
  *Change Items* (126), *Change Weapons* (127) and *Change Armor* (128) — adding
  or removing a constant or variable amount. The Conditional Branch **item /
  weapon / armor** possession tests (types 8 / 9 / 10) are evaluated, and Control
  Variables can read an **item count** (operand type 3) as its source. Covered by
  new `mruby-rpgxp/test` cases (inventory clamping + save round-trip, the three
  change commands with constant and variable operands, the possession
  conditionals, and the item-count variable operand).
