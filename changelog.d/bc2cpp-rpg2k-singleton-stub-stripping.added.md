- **`mruby-rpg2k`'s wio-only bytecode-stub-stripping (docs/adr/0144) now
  covers 21 of its 25 `.singleton` (class-method) owners** —
  `Game.singleton`, `Game::States.singleton`, `Game::ChipsetLayout.singleton`,
  `Game::EventGraphic.singleton`, `Game::Transition.singleton`,
  `Game::Party.singleton`, `Game::Picture.singleton`,
  `Game::Character.singleton`, `Game::ChipSet.singleton`,
  `RPG2k::Scene::Map.singleton`, `Game::MoveType.singleton`,
  `Game::MapAccess.singleton`, `Game::Parallax.singleton`,
  `Game::MessagePalette.singleton`, `Game::MapBgm.singleton`,
  `Game::WindowCursor.singleton`, `Game::Message.singleton`,
  `Game::EventPage.singleton`, `Game::CharSet.singleton`,
  `Game::Backdrop.singleton`, `RPG2k::Scene.singleton` — 64 real
  bc2cpp-registered `def self.foo` methods total, confirmed by a real
  `wio_registered_methods.rb` run, an AST-based companion-statement and
  gem-init-ordering hazard check, and a real strip+parse+AST-diff dry run
  (`game.rb` 163,046 → 150,990 bytes, `scene/map.rb` 196,496 → 196,349
  bytes, `scene/base.rb` 11,199 → 11,024 bytes, real host `mrbc -g`
  measurements). The other 4 real `.singleton` candidates
  (`Game::States::BattleText`, `Game::Battle`, `Game::State`,
  `Game::BattlePage`) are confirmed no-ops for wio today — every one of
  their own registered methods lives in a file (`game/battle_support.rb`,
  `game/battle.rb`, `game/lsd_io.rb`) wio's own build already excludes —
  and are left out of `owners:` rather than added pointlessly.
