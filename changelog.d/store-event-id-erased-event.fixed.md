- **Store Event ID now still resolves a temporarily-erased event at the tile
  it occupied when it was erased**, instead of reading back 0 there for the
  rest of the visit. `Scene::Map#erase_event` dropped an erased event's tile
  from `@event_tiles` outright — correct for collision and drawing, which
  RPG_RT's Erase Event does stop, but `event_id_at` (the Store Event ID query)
  read that same table, so it lost the id too, which yado.tk documents RPG_RT
  keeps answering. `erase_event` now also freezes the tile in a new
  `@erased_event_positions` (an erased event cannot move further, so one
  snapshot at erasure time is enough), and `event_id_at` falls back to it,
  still resolving several ids sharing a tile — live, erased, or a mix — to the
  highest one, matching the existing overlapping-events rule. An event whose
  current page conditions simply aren't met is a separate, still-open half of
  the same yado.tk claim, left for a follow-up. Covered by three new
  `scripts/rpg2k_scene_check.rb` checks, two confirmed to fail against the
  pre-fix code before the fix.
