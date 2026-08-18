- **Map events:** Control Variables' "Characters" X/Y/Direction operand and
  Conditional Branch's "Character Direction is" test now resolve an erased
  or currently-inactive-page map event at its last known position and
  facing, matching real RPG_RT — they used to read 0/false (with a "map
  event not found" warning) for any event outside its own live page, the
  same gap Store Event ID already had fixed for it. Reuses the existing
  `@event_last_position` fallback table. Covered by new
  `scripts/rpg2k_scene_check.rb` checks.
