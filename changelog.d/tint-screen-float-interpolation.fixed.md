- **RPG2000/2003 maps:** Tint Screen's per-frame interpolation now keeps
  full precision between frames instead of feeding the previous frame's
  already-rounded channel value back into the next frame's own
  calculation, matching RPG_RT's own float-precision interpolation
  (truncated only where the tint is actually drawn) — the same bug already
  fixed for Move Picture, now applied here too. Previously the rounding
  error compounded frame over frame, producing a slightly different
  darkening-overlay opacity during any Tint Screen transition whose
  duration doesn't evenly divide the distance — the common case. Covered
  by a new `scripts/rpg2k_logic_check.rb` check.
