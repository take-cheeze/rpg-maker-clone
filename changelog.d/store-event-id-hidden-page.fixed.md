- **Store Event ID (and its "Get Event ID at Location" name on yado.tk) now
  resolves an event whose current page conditions aren't met**, at wherever it
  last stood, instead of reading back 0 there for the rest of the visit. Such
  an event never gets a `Game::Character` built at all (`Scene::Map#build_events`
  skips it outright whenever no page's conditions are satisfied), but real
  RPG_RT keeps one `Game_Event` object per map event for the whole visit
  regardless of page state and answers `Game_Interpreter::CommandStoreEventID`
  from it with no "is this page active" check at all
  (`Game_Map::GetEventAt(x, y, /* require_active */ false)`,
  `src/game_map.cpp`). Fixed with a new per-visit `@event_last_position`
  table, seeded from an event's raw map placement the first time it is ever
  seen this visit and kept live for as long as it has an active page, that
  `#event_id_at` now falls back to for any id that is neither currently live
  nor erased — with the same highest-id tie-break the already-fixed
  temporarily-erased-event case uses. Covered by three new
  `scripts/rpg2k_scene_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
