- **The Item screen's list is now a two-column grid, matching genuine
  RPG_RT.exe.** Verified under wine with a populated bag: RPG_RT fills the
  list row-major across two columns rather than stacking every item on its
  own row, and cursor movement is grid-aware (DOWN/UP move a row, RIGHT/LEFT
  move a column, all blocked rather than wrapping at a missing cell).
  `Scene::ItemMenu` now lays out and navigates the same way, replacing its
  old single-column modulo-wraparound cursor with the confirmed grid
  behavior and adding RIGHT/LEFT input handling it never had before.
