- `Game::State#to_lsd`/`.from_lsd` now encode chunk 108's states field (81
  count / 82 data) as a dense array, one slot per database state id, instead
  of a sparse list of only the currently-afflicted ids. A genuine kk1.12
  (RPG2003) save under wine carries field 81 as the game's own total state
  count (30) on every actor, none of them afflicted with anything — matching
  EasyRPG Player's own live source (`Game_Battler::GetInflictedStates`,
  `src/game_battler.cpp`), which walks this same dense, per-state-id vector.
  This codebase's own writer previously wrote nothing at all for an
  unafflicted actor (an empty sparse list) and, for an afflicted one, a
  short array of literal state ids at the wrong field length entirely — a
  save written by this engine's own Save/Continue would have desynced state
  data from any tool (including a genuine RPG_RT.exe) expecting the real
  per-state-id layout. `Actor#total_state_count` is new, reading the
  database's own state table size.
