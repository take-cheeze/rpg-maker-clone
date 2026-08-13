- **A special item invoking an Escape or Teleport skill is castable from the
  field Item menu now**, not silently unusable. `Game::Party#field_usable?`
  called `#field_skill?` with no `Game::State`, so the Escape/Teleport arm
  always read "unsupported" and such an item never appeared in the list, even
  with access on and a destination registered. `#field_usable?` / `#field_items`
  now take an optional `state`, threaded through from `Scene::ItemMenu` exactly
  as `Scene::SkillMenu` already threads it into `#field_skills`. Casting is
  free (the item is the cost, mirroring every other special item): new
  `Game::Party#use_special_escape_item` / `#use_special_teleport_item` reuse
  `#cast_escape_skill` / `#cast_teleport_skill` via a new `free` flag on each
  (mirroring `#cast_skill`'s own), and `Scene::ItemMenu` gained a Teleport
  destination picker mirroring `Scene::SkillMenu`'s. Covered by new
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb` checks,
  confirmed to fail against the pre-fix code before the fix.
