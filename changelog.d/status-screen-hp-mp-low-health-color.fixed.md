- **Status screen:** the current HP figure now shows in the windowskin's
  own gray "knocked out" swatch at 0 HP, and the current HP/MP figure
  shows in the "critical" swatch at a quarter of max or below -- matching
  RPG_RT's `Window_Base::GetValueFontColor` -- previously the whole HP/MP
  row always drew in a flat default color regardless of how low either
  figure was.
