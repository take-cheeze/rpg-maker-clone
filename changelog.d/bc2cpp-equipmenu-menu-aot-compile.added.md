- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 29 of
  `RPG2k::Scene::EquipMenu`'s own 36 real bytecode methods (the field
  equip screen: weapon/armor/accessory slot selection, a two-column
  candidate grid, per-stat before/after deltas) and 28 of
  `RPG2k::Scene::Menu`'s own 35 (the field main menu: the top-level
  party navigation hub, party-status panel, end-game confirmation
  dialog, gold display). Both added to `mruby-rpg2k-compiled`. Neither
  needed any new opcode work; every remaining gap is a non-mandatory
  argument, a genuine Ruby block or lambda, a `rescue` clause, or a
  `super` call. See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
