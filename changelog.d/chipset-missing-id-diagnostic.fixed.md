- **A dangling chipset id now logs a diagnostic instead of silently
  rendering a map blank and fully passable.** `Game::ChipSet#initialize`
  (`mruby-rpg2k/mrblib/game.rb`) already degraded every field (name, graphic,
  passability tables, terrain data, animation params) to a safe blank/nil
  default when `db.chipset[id]` missed — matching the same graceful-degrade
  philosophy `Game::Party#db_enemy_group`/`Game::Enemy` use — but nothing
  ever reported the gap, so a map with a stale `chipset_id` (or a Change Map
  Tileset override to a bad id) rendered with zero diagnostic trace. It now
  logs a `[RPG2k] chipset #<id> not found in database, tiles treated as
  blank/passable` message, `respond_to?`-guarded the same way
  `db_item`/`db_enemy_group` are so a bare test fixture with no chipset
  table at all stays quiet. The degrade behaviour itself is unchanged; this
  is diagnostics only. Covered by a new `scripts/rpg2k_logic_check.rb`
  check.
