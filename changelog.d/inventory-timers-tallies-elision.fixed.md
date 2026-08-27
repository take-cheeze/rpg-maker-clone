- `Game::State#to_lsd` now elides chunk 109 (SAVE_INVENTORY)'s timer fields
  (23-30) and battle tallies/step counter (32-35, 42) at their own
  never-touched default (0/false) instead of always writing them. Confirmed
  against a genuine kk1.12 save under wine, taken well into a real
  playthrough: every one of these fields was still absent, matching
  liblcf's own `generator/csv/fields.csv` declared defaults — `#to_lsd`
  previously wrote all of them unconditionally.
