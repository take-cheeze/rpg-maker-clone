- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 17 of
  `RPG2k::Scene::Base`'s own 29 real bytecode methods (the common
  windowskin/field-backdrop/scrolling-list/system-text/system-SFX
  superclass every other `RPG2k::Scene::*` class inherits from,
  including its own `#initialize`) and 14 of `Game::Character`'s own 16
  (the shared moving-on-map-entity state/movement protocol
  `Game::Vehicle` and the player/event drivers build on). Both added to
  `mruby-rpg2k-compiled`. Neither needed any new opcode work -- every
  remaining gap is a non-mandatory argument, a genuine Ruby block, or a
  `rescue` clause, all already-established out-of-scope shapes.
  `RPG2k::Scene::Base#initialize` now compiling clean also identifies a
  concrete lead for a future round: `RPG2k::Scene::ItemMenu`/
  `DebugMenu`/`Menu` (already shipped) are each blocked from their own
  `#initialize` compiling purely by their own `super parent` call into
  `Base`, a real `SUPER`-opcode candidate. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
