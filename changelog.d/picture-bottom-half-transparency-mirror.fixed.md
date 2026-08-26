- `Game::State#to_lsd` now writes chunk 103 (Show Picture) fields 18
  (`current_bot_trans`) and 35 (`finish_bot_trans`) as plain mirrors of fields
  8 (`current_top_trans`) and 34 (`finish_top_trans`). liblcf's own
  `generator/csv/fields.csv` documents 18/35 as RPG2003's independent
  bottom-half transparency for its pre-1.12 top/bottom split effect, and a
  genuine kk1.12 (RPG2003) save under wine carries both halves present with
  identical values even though it never exercises a real split — `#to_lsd`
  previously never wrote 18/35 at all, so a picture round-tripped through
  this engine's own Save/Continue lost the bytes a genuine RPG_RT.exe always
  carries alongside the top half. `Game::Picture` has no split of its own to
  restore from, so this is a write-only byte-parity fix, not new gameplay
  behavior — confirmed against a real kk1.12 save that chunk 103 is now
  byte-for-byte identical after a load/re-save round trip.
