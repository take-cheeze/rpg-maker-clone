- **A map event's Move Route "Change Graphic" override no longer resets when
  a *different* event's page flips.** `Scene::Map#pages_changed?` is a
  map-wide check — any Control Switch/Variable/item/party write that flips
  *any* event's active page triggers `#rebuild_events_preserving_positions`,
  which rebuilds every event's `Game::Character` from scratch via
  `#build_event`, and `#build_event` always sets `graphic_name`/
  `graphic_index` fresh from whichever page it was just given (unlike
  Through Mode/Direction Fix/Stop Animation/Transparency, which no page ever
  sets, already fixed the same way for those four). An event whose own page
  never changed still lost whatever a Set Move Route Change Graphic
  sub-command had drawn it as, silently snapping back to its page's own base
  sprite the instant some *other* event's Control Switch/Variable write flipped
  a page anywhere on the map — well before the map transfer/save-load yado.tk
  documents the override as actually reverting on (unlike the dedicated
  Change Graphic event command). Fixed by carrying `graphic_name`/
  `graphic_index` across the rebuild too, but only for a bystander whose own
  page selection did not move (`old[:page].equal?(e[:page])`, the same
  page-identity test `#pages_changed?` and the move-route-continuation check
  already use) — an event whose own page genuinely does change to a
  different base sprite still gets that new page's own graphic, not a stale
  override painted back over it. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (a bystander event's override survives
  an unrelated event's switch-triggered page change, while a third event's
  own page change to a different base sprite still wins), confirmed to fail
  against the pre-fix code before the fix.
