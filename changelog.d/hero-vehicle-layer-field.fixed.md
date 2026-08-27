- `Game::State#to_lsd` now writes chunk 104/105-107's field 33 (liblcf's own
  `layer`) as the constant 1 ("same as characters") for the hero and every
  vehicle. Confirmed present with exactly this value on a genuine kk1.12
  save under wine, on the hero's own record and every vehicle's alike — this
  codebase has no "Change Hero/Vehicle Layer" concept to source a live value
  from (RPG2000/2003 never offers one outside a map event's own page), so
  the field is a true constant, one more piece of the larger `SaveMapEventBase`
  gap documented in `mruby-lcf/mrblib/schema.rb`'s `SAVE_MOVABLE` comment.
