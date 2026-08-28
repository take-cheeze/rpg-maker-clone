- **A live Set Move Route (11330) forced route targeting the hero now
  survives Save/Continue.** Previously tracked only as `Scene::Map`'s own
  transient `@player_route`/`@player_char`/`@player_through` instance
  variables, invisible to both save formats — a save taken mid-route and
  continued silently dropped it, leaving the hero walking freely instead of
  resuming the forced route. Promoted onto `Game::State#player_route`/
  `#player_through`, round-tripped through both the portable Marshal save
  (`#to_h`/`#load_h`) and a genuine `.lsd` (`#to_lsd`/`.from_lsd`, chunk 104's
  own `move_frequency`/`move_route`/`move_route_index`/`through`, liblcf's
  generator/csv/fields.csv fields 0x20/0x29/0x2B/0x33 — 32/41/43/51). The
  route's own command list reuses this codebase's own already-tested
  `LCF::Schema::MOVE_ROUTE`/`parse_move_commands`/`encode_move_commands`
  (the same byte format `MAP_EVENT_PAGE`'s own custom-route field already
  exercises across the full test-bed corpus, confirmed against EasyRPG's
  own liblcf source). Confirmed byte-for-byte against a genuine kk1.12 save
  under wine, including the field 21/22 (`repeat`/`skippable`) per-field
  "omit at own default" split. The route's own step-pacing timer is not
  part of either save format, so a save resumed mid-route restarts that
  timer from 0 rather than wherever it was mid-count — the same category of
  imperfection already accepted for the hero's own Flash Sprite decay curve.
