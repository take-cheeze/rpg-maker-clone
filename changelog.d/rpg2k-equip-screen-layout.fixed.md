- **RPG2000 Equip screen** now matches genuine `RPG_RT.exe`, measured under
  wine: the four windows tile the screen the way the real runtime lays them
  out (description banner 0,0 320x32; stat panel 0,32 124x96; the slot list
  *beside* it at 124,32 196x96; the candidate grid 0,128 320x112), and all
  four stay live at once -- the grid is filled as soon as the screen opens
  and re-fills in place as the slot cursor moves, instead of replacing the
  slot list on Decision. Each stat row now reads term / right-aligned figure
  / full-width `→` / right-aligned preview in the windowskin's own measured
  swatches (system blue for the terms and arrow, white for the figures,
  peach for a rise and blue for a fall); the slot list draws its label and
  worn item in their measured columns and leaves an empty slot blank rather
  than printing `-`; and the candidate grid is now the same widget the Item
  menu draws -- 144px cells at content x 0/160, `:` plus a right-aligned
  count at each cell's right edge, and row-at-a-time scrolling with the
  blinking windowskin arrows once the list outgrows its six rows.
- **RPG2000 equip candidate list** now follows the bag's own stored order
  instead of sorting by item id, matching genuine `RPG_RT.exe`.
