- **Save/Load screen:** the face-thumbnail row now draws from the save's own
  title-chunk snapshot (taken at save time), matching RPG_RT — previously it
  re-derived faces from the currently-loaded party's live data, which could
  disagree with what a real save actually shows. The row is also now
  flush with the slot box's right edge with no trailing gap, correcting an
  8px-too-far-left position.
