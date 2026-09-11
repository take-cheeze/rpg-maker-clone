- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 9 of
  `Game::EnemyAi`'s own 10 real bytecode methods (`Game::Battle`'s own
  enemy action-pattern collaborator: skill-table lookups, casting-
  eligibility formulas, switch read/write, party average level) and all
  9 of `Game::ChipSet`'s own real bytecode methods (one loaded chipset's
  own tile graphic name, lower/upper passability tables, terrain table,
  and water-animation parameters). Both added to `mruby-rpg2k-compiled`.
  Neither needed any new opcode work. `Game::ChipSet` is the fifth target
  (after `Game::Screen`/`Game::Transition`/`Game::State`/`Game::Map`)
  whose own ivars get real `RData` embedding: `@animation_type`/
  `@animation_speed` are both provably Fixnum, verified safe against the
  earlier `Game::Actor` embedding bug the same way every prior embedding
  target was. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
