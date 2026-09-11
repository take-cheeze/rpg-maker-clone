- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 12 of
  `RPG2k::Scene::SaveLoad`'s own 22 real bytecode methods (the file-select
  screen shared by Scene::Menu's Save command and Scene::Title's Continue
  entry) and 12 of `RPG2k::Scene::Order`'s own 16 (the RPG2003 field Order
  party-reorder screen). Both added to `mruby-rpg2k-compiled`. Neither
  needed any new opcode work -- every remaining gap is a `super` call
  into `RPG2k::Scene::Base` or a genuine Ruby block, both already-
  established out-of-scope shapes. `#initialize`'s own `super` call in
  each identifies two more concrete leads for a future `SUPER`-opcode
  round, alongside the three already found. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
