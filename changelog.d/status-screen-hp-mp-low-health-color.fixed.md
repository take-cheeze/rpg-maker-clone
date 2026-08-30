- **Status screen:** the current HP figure now shows in the windowskin's
  own gray "knocked out" swatch at 0 HP, and the current HP/MP figure
  shows in the "critical" swatch at a quarter of max or below -- matching
  a reference implementation's own value-color rule, not independently
  confirmed against genuine RPG_RT under wine -- previously the whole HP/MP
  row always drew in a flat default color regardless of how low either
  figure was.
