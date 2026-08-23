- **Save/Load screen:** the file-select cursor now clamps at the first and
  last slot instead of wrapping around, matching RPG_RT — previously a
  fresh key tap wrapped past either end (a held key already clamped
  correctly), but real RPG_RT never wraps this list at all.
