- **The battle result window now shows the database's own Victory / Defeat
  wording**, not a hardcoded English sentence. The 用語 (vocabulary) table's
  `victory` and `defeat` fields — the same table
  `Game::States::BattleText` already reads every per-action battle log line
  from — were parsed but never consulted here, so a fight always ended on
  "Victory!" / "The party was defeated..." regardless of what the database
  actually said. Those two strings are now exactly what shows when the field
  is left blank, matching the fallback convention every other battle-log line
  already follows, rather than the only wording a game ever showed.
  `Game::Party`'s EXP / gold / item lines stay composed English for now: their
  own terms (`exp_received`, the `gold_received_a` / `_b` pair,
  `item_received`) are two- or three-part sentences with the number or item
  name sandwiched between literal halves, and there's no real database on hand
  to confirm which half goes where — left declared rather than guessed at.
  Covered by two new checks in `scripts/rpg2k_scene_check.rb` (a database term
  is shown verbatim; a blank one still falls back to the composed English).
