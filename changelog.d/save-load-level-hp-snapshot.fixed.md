- **Save/Load screen:** the Lv/HP line now draws from the save's own
  title-chunk snapshot (taken at save time), matching RPG_RT — previously
  it re-derived level/HP from the currently-loaded leader's live data,
  the same class of bug already fixed for the face-thumbnail row.
