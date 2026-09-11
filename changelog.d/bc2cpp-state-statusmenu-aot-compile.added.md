- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 23 of
  `Game::State`'s own 32 real bytecode methods (the whole-program root
  save/session object: party, switches, variables, map position,
  pictures, timers, screen-transition defaults, vehicle placement, the
  `.lsd` save-file (de)serialisers) and 13 of
  `RPG2k::Scene::StatusMenu`'s own 21 (the field per-character status
  detail screen). Both added to `mruby-rpg2k-compiled`. `Game::State`'s
  own `#initialize` compiles (4 purely mandatory arguments), so 13 of
  its provably-Fixnum ivars now get real `RData` struct embedding --
  the third class to do so after `Game::Screen`/`Game::Transition` --
  confirmed safe against the earlier `Game::Actor` memory-safety shape:
  `Game::State.load` (the save-file loader) always constructs new
  instances through the real, struct-allocating `#initialize`, never
  around it. Neither class needed any new opcode work. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
