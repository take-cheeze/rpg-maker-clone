- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 6 of
  `RPG2k::Scene::Title`'s own 20 real bytecode methods (the title
  screen's New Game/Continue/Exit menu) and 7 of
  `RPG2k::Scene::MapWorld`'s own 8 (the small adapter bridging
  `Game::MoveRoute`/`Game::MoveType`'s own movement protocol onto the
  owning map scene). Both added to `mruby-rpg2k-compiled`, neither
  needing any new opcode work. `RPG2k::Scene::Title#move_selection`'s own
  `%`-based cursor-wraparound arithmetic directly exercises a prior
  round's operator-name-extraction fix. Identifies `RPG2k::Scene::
  VehicleWorld` -- an identically-shaped adapter class in the same file
  -- as a concrete lead for a future round. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
