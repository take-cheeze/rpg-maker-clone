- `mruby-rpg2k-compiled` ships this project's first `.singleton`-owned
  compile targets outside `mruby-rgss-compiled` -- 70 real, compiled entry
  points across 12 `Game::`/`RPG2k::` classes' own `def self.x`/
  `class << self ... end` methods, registered via `mrb_define_class_method`
  the same way `RGSS::Bitmap.singleton` established.

  `Game::States.singleton` (13 methods, split across `mruby-rpg2k/mrblib/
  game.rb` and a second `module States` reopening in `mruby-rpg2k/mrblib/
  game/battle_support.rb`), `Game::States::BattleText.singleton` (13
  methods -- this project's first `.singleton` owner nested two levels
  deep, `Game::States::BattleText`, confirmed the existing owner-scope-
  chain fix already handles it correctly with zero further changes),
  `Game::ChipsetLayout.singleton` (10 methods) and `Game::EventGraphic.
  singleton` (9 methods) were the round's priority targets; a cheaper
  "already-owned class, add its own `.singleton` half too" pass then
  covered 8 more classes `mruby-rpg2k-compiled` already owned on their
  instance side -- `Game::Battle.singleton` (11), `Game::Transition.
  singleton` (6), `Game::State.singleton` (2), `Game::Party.singleton`
  (2), `Game::Picture.singleton`, `Game::Character.singleton`,
  `Game::ChipSet.singleton`, and `RPG2k::Scene::Map.singleton` (1 each).

  All 70 methods were re-verified compiling clean in a real `ONLY_OWNERS`
  run (not just the unrestricted whole-program diagnostic that first
  found them), with several already-compiled call sites elsewhere in the
  gem (`RPG2k::Scene::Battle`'s own battle-log lines, `RPG2k::Scene::Map`'s
  own event/chipset rendering) confirmed flipping from ordinary dynamic
  dispatch to a direct devirtualized C++ call now that these owners are
  covered. Verified with a full before/after diff across all three
  compiled gems: every already-shipped owner's own generated code, ivar
  embedding, and whole-program MONO/POLY registry entry count are
  byte-for-byte unchanged -- confirmed by `nm` on real compiled objects,
  not just by inspection.
