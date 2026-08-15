- `Scene::Map#char_passable?`/`#char_can_land?` now tell the hero apart from
  a map event by id (`Game::Character#event_id`) rather than by comparing
  the mover against `@player_char` with `equal?`. `Game::Character` gained
  an `event_id` accessor, set to the event's own id in `#build_event` and to
  `MOVE_TARGET_PLAYER` (10001) on the party's forced Set Move Route mirror in
  `#start_player_route`; `character.event_id == MOVE_TARGET_PLAYER` replaces
  `character.equal?(@player_char)` as the "is this the hero" test both
  methods use to gate `vehicle_blocks?`'s airship exemption and the
  `overlap_forbidden` exemption added alongside the priority-type collision
  fix above.
