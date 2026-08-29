- **Main menu party list, and the Item/Skill target-actor list:** the
  current HP figure now shows in the windowskin's own gray "knocked out"
  swatch at 0 HP, and the current HP/MP figure shows in the "critical"
  swatch at a quarter of max or below -- matching RPG_RT's own
  value-font-color rule (taken from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine), the same
  rule already ported for the field Status screen and the battle status
  panel. Previously these two
  screens' own "Lv X HP a/b MP c/d" rows always drew in a flat default
  colour regardless of how low either figure was, the same gap those other
  two screens had before their own earlier fixes.
