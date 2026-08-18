- **RPG2000/2003 pictures:** Move Picture's per-frame easing now keeps full
  precision between frames instead of feeding the previous frame's
  already-rounded position back into the next frame's own calculation,
  matching RPG_RT's own float-precision interpolation (truncated only at
  display time). Previously the rounding error compounded frame over frame,
  producing a visibly different, slightly laggier motion path for nearly
  any Move Picture whose distance isn't an exact multiple of its duration —
  the common case. Covered by a new `scripts/rpg2k_logic_check.rb` check.
