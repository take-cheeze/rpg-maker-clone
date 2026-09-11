- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 6 of
  `RPG2k::Scene::VehicleWorld`'s own 7 real bytecode methods (the same
  `world` protocol adapter `RPG2k::Scene::MapWorld` exposes to the
  movement engine, adapted for a vehicle instead of the hero) and 6 of
  `Game::TextReveal`'s own 11 (the message-window character-by-character
  text reveal/typewriter-effect backing model). Both added to
  `mruby-rpg2k-compiled`, neither needing any new opcode work.
  `RPG2k::Scene::VehicleWorld` is the third target (after
  `Game::ChipSet`/`Game::Switches`) whose own ivars get real `RData`
  embedding, and the first where the embedded field is a Symbol rather
  than a Fixnum: `@type` is always a literal from `Game::Vehicle::TYPES`,
  verified safe the same way every prior embedding target was. Verifying
  `#set_switch` also surfaced (and confirmed not live) a real whole-
  program registry-soundness gap: `Game::State#switches` is an
  `attr_reader`, structurally invisible to the devirtualization
  registry's own native-method scanner, unlike the native-method-table
  and `MRB_SYM_Q/B/E` shapes a prior round's fix already covers. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
