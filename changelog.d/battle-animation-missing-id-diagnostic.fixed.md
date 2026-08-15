- **A dangling battle-animation id now logs a diagnostic instead of silently
  drawing nothing.** `Scene::Map#animation_row`
  (`mruby-rpg2k/mrblib/scene/map.rb`) — the single choke point every
  battle-animation lookup goes through, whether from a Show Battle Animation
  command or a skill/item's own animation — used to swallow a miss with a
  bare `rescue StandardError; nil`. It now logs a `[RPG2k] battle animation
  #<id> not found in database, nothing drawn` message, `respond_to?`-guarded
  the same way `terrain_row_at`/`db_item` are so a bare test fixture with no
  `battle_anime` table at all stays quiet. Drawing nothing is unchanged; this
  is diagnostics only. Covered by new `scripts/rpg2k_scene_check.rb` checks.
