- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 75 of
  `Game::Battle`'s own 141 real bytecode methods (turn order, command
  resolution, hit/damage/state-infliction formulas, enemy AI action
  selection) and 41 of `RPG2k::Scene::ItemMenu`'s own 47 (the field/battle
  item-use menu, including teleport-item map picking). Both added to
  `mruby-rpg2k-compiled`. Neither needed any new opcode work -- every
  remaining gap is a non-mandatory `#initialize`/method argument, a
  genuine Ruby block, a `rescue` clause, or (`Game::Battle#initialize`) a
  `super` call, all already-established out-of-scope shapes. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
