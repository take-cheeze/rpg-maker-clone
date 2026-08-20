- **Teleport destination picker:** With three or more registered
  destinations, Right/Left now flow across a row boundary instead of
  stopping at the row's own edge, matching RPG_RT -- the same fix already
  applied to the item/skill lists, now propagated to this sibling list.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks.
