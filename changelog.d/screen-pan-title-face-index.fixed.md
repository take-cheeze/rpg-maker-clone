- `Game::State#to_lsd` now writes chunk 102 (SAVE_SCREEN) fields 41/42
  (`pan_x`/`pan_y`, liblcf's own generator/csv/fields.csv names), restoring
  a live Pan Screen offset through Save/Continue. Confirmed against a
  genuine kk1.12 save under wine: field 42 (pan_y) was present and
  nonzero, field 41 (pan_x) absent at its own default 0 — `#to_lsd` never
  wrote either field before, even though `Game::Screen` already tracks
  this offset for the portable Marshal save format. Documented (no
  behavior change) the larger remaining gap in this same chunk: liblcf's
  own battle-animation fields (43-47), which `Game::Screen` has no
  equivalent "last played" state to source from at all.
- `Game::State#to_lsd` now elides chunk 100 (SAVE_TITLE)'s four FaceSet
  index fields (22/24/26/28) at their own default (0) instead of always
  writing them, matching a genuine kk1.12 save under wine whose leader's
  face index was 0 and left the field absent.
