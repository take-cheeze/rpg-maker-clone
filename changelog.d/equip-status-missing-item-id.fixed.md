- **The Equip and Status screens no longer show a dangling equipped item id
  with no trace.** `Scene::EquipMenu#item_name` / `Scene::StatusMenu
  #item_name` (`mruby-rpg2k/mrblib/scene/equip_menu.rb` /
  `mruby-rpg2k/mrblib/scene/status_menu.rb`) already degraded a slot whose
  `db_item(id)` lookup missed to an `"Item #<id>"` placeholder label instead
  of crashing, but logged nothing, so a database shrink leaving a stale
  equipped id behind was invisible. Both now log a `[RPG2k] Equip screen:
  item #<id> not found in the database, showing a placeholder label` /
  `[RPG2k] Status screen: ...` diagnostic the first time a dangling id is
  hit, deduped per item id for the scene's lifetime so repeated LEFT/RIGHT
  actor switches don't spam the console; the placeholder label itself is
  unchanged. This is the equipped-slot *display* manifestation of the
  "invalid item" case in docs/TODO.md's runtime error catalog, distinct from
  the field/battle Item-menu's own inventory-*list*-filtering manifestation.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks.
