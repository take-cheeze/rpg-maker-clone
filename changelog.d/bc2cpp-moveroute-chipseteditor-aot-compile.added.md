- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 18 of
  `Game::MoveRoute`'s own 19 real bytecode methods (the RPG2000 "Set
  Move Route" event-command engine) and 17 of
  `RPG2k::Scene::ChipsetEditor`'s own 20 (the F9 debug menu's tile-
  passability grid editor). Both added to `mruby-rpg2k-compiled`.
  Neither needed any new opcode work. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
