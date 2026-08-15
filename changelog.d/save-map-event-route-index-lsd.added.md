- **A map event's mid-route position (chunk 111, `SAVE_MAP_EVENT`/
  `SAVE_MOVABLE`) now round-trips through a real `.lsd` save, not just the
  portable Marshal save.** `Game::State#map_event_positions`/
  `#map_event_route_index` already tracked a wandering event's live tile
  position and its page's own custom-route cursor, matching real RPG_RT's
  `SaveMapEvent` chunk — but `#to_lsd` never wrote chunk 111 at all, and
  `.from_lsd` never read it back, leaving genuine editor saves unable to
  resume either. `LCF::Schema::SAVE_MOVABLE` gains field 43
  (`move_route_index`, sourced from EasyRPG's liblcf
  `generator/csv/fields.csv`, `SaveMapEventBase.move_route_index` == 0x2B)
  alongside the already-documented position fields (12/13/22); `#to_lsd`
  writes both for every event the current map has snapshotted a position for
  (undefaulted, so a save taken before any custom-route cursor was recorded
  leaves the field genuinely absent), and `.from_lsd` restores them the same
  way `Scene::Map#build_event` already consults them for a Marshal-save
  Continue. `SaveMapEvent.original_move_route_index` (liblcf 0x66, the route
  in force *before* a Set Move Route override) stays unmodelled: this
  codebase has no separate "original vs current route" concept to source it
  from. Covered by a new `scripts/rpg2k_logic_check.rb` check: a mid-route
  event's position and cursor round-trip through `to_lsd`/`from_lsd`, and a
  legacy save missing field 43 falls back to the existing "no saved index"
  default (route restarts at 0) rather than erroring.
