- **Map events:** Change Event Location and Trade Event Locations now
  reposition a hidden (page condition currently unmet) or temporarily-erased
  map event, matching real RPG_RT — they used to silently do nothing against
  such a target, and for Trade Event Locations that aborted the *whole* swap,
  so even the other, perfectly live, participant failed to move. Reuses the
  existing `@event_last_position`/`@erased_event_positions` fallback tables.
  Covered by new `scripts/rpg2k_scene_check.rb` checks.
