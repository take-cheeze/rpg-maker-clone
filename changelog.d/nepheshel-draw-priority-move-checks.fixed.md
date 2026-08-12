- **Same-layer characters now draw in their own y-order, not just against the
  hero.** `event_target_buffer` correctly bucketed a "same as hero" event
  above or below the player sprite, but two such events sharing a bucket were
  painted in event-array order rather than sorted against each other, so
  whichever was defined later in the map always drew on top regardless of
  position. `draw_events` now sorts by screen y (then x, then event id) before
  painting, matching RPG_RT's own `Game_Character#GetScreenZ` tie-break.
- **A step is now blocked when the tile being left disallows it, not only
  when the tile ahead does.** RPG2000's per-direction passability is a
  two-sided agreement: the tile a character is leaving must permit exit
  toward the direction of travel, and the tile it is entering must permit
  entry from the opposite side. The player's `passable?` and the event/
  MoveRoute `char_passable?` only asked the destination, and asked it with
  the direction of travel rather than the reverse — so a character could walk
  off a tile whose own edge disallowed it, and a tile's own exit-only bit
  could wrongly stand in for its entry bit. Nepheshel ships 513 such
  direction-restricted tiles across 17 of its 100 chipsets. A jump's landing
  check (`char_can_land?`) is fixed the same way it actually differs: RPG_RT
  ORs a jump destination's four direction bits together rather than testing
  one specific side, since a jump has no single direction of entry the way a
  step does. Covered by new checks in `scripts/rpg2k_scene_check.rb` and
  `scripts/rpg2k_logic_check.rb`.
