- **`wio_strip_bc2cpp_stubs` (docs/adr/0144) now also covers 13 plain
  `RPG2k::Scene::*` menu/scene owners** — `ItemMenu`, `SkillMenu`,
  `EquipMenu`, `Menu`, `StatusMenu`, `SaveLoad`, `Order`, `Base`, `Title`,
  `MapWorld`, `VehicleWorld`, `EventResolver`, `GameOver` (216 real
  bc2cpp-registered methods; 213 actually strip out of wio's own copy of
  `base.rb` — `Base`'s remaining 3 registered methods
  (`advance_list_arrow_anim`, `list_arrow_blink_on?`, `sticky_list_top`)
  live in a second `class Base` reopening inside `mrblib/scene/battle.rb`,
  which is already dropped from wio's own `spec.rbfiles` by the existing
  wio-only battle trim, so this mechanism never sees them). Same profile
  round 35 already proved out for `game.rb`: plain instance methods only,
  none of them in bc2cpp.rb's own `DIRECT_CONSTRUCT_TARGETS`/
  `NATIVE_ARG_TARGETS` allowlists. Real, measured `mrbc -g` reduction of
  the 10 affected source files combined: 114,633 → 49,824 bytes
  (-64,809, 56.5%).
- No `Game::ChipSet`-style exclusion was needed for any of these 13
  owners: a real AST walk of all 10 files' own class bodies found only
  bare `private` mode switches (or none at all) and one
  `attr_reader :parent, :db, :map_tree` (`base.rb`'s own `Base` class,
  none of those three names colliding with any of its 17 registered
  methods) — no explicit `private :name`/`protected :name`/`public :name`/
  `alias_method` anywhere in scope.
