- An item whose database row carries a blank name now draws a blank name in the
  Item, Equip and Status screens, instead of an invented `Item <id>`
  placeholder. Measured against genuine `RPG_RT.exe` under wine, which leaves
  the name column empty and still draws the count. The placeholder survives only
  for an id with no database row at all, which is a broken-data diagnostic.
