- **wio's `RPGMAKER_BC2CPP` build now also strips the interpreted-bytecode
  body of `Game::Party`'s own 69 game.rb-resident bc2cpp-covered methods**
  (docs/adr/0144), including `#swap_equipment_through_bag` — the private
  method whose own companion `private :swap_equipment_through_bag`
  statement round 35 flagged as a standing hazard; round 38's
  companion-statement-stripping mechanism now removes both together,
  verified with a real CRuby `load` of the rewritten source raising no
  `NameError`. `Game::Party` has 85 real registered methods total (ground
  truth from a real `wio_registered_methods.rb` run); the other 16 are
  defined in `game/battle_support.rb`, already excluded from wio's own
  `spec.rbfiles`, so they strip nothing there. Real `mrbc -g` measurement:
  -14,728 bytes off `game.rb` on top of every prior round's own
  already-shipped owners. `Game::Battle` (72 registered methods) was
  investigated but not added: its entire real class body lives in
  `game/battle.rb`, itself already dropped from wio's `spec.rbfiles` by
  the existing wio-only battle trim, so listing it as an owner would
  strip nothing for wio today — the same "pointless, not unsafe" shape as
  the four already-omitted `.singleton` battle-only owners.
  `Game::Interpreter`/`RPG2k::Scene::Map`/`RPG2k::Scene::Battle` remain
  deferred for a future round (173/224/110 methods, too large for the
  same rigor in one round).
