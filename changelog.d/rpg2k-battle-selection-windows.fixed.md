- **RPG2000 battle selection windows** re-measured on genuine RPG_RT.exe under
  wine: the enemy-target, Skill, Item and ally-target lists now draw their
  names through the windowskin's font gradient instead of flat white; the
  Skill/Item grids use RPG_RT's 160px column pitch of 144px cells with the SP
  cost (`-`) and held count (`:`) right-aligned in their own column; both
  grids gained the description banner RPG_RT shows above them; the list a
  target cursor was opened from stays on screen underneath it; the ally
  target is now a cursor on the party status panel rather than a separate
  name/HP list; and Down off the last full row of an overflowing grid reaches
  the partial row's lone entry instead of blocking.
