- **Save/Load:** the `bgm_stopping` flag a Fade Out BGM sets (forcing the
  next same-name Play BGM/Play Memorized BGM to restart from the top
  instead of silently continuing) now survives a Save/Continue, matching
  liblcf's `SaveSystem` field 61 (`music_stopping`). Previously the flag was
  session-only and silently reset to "not stopping" on every load, so a
  game that faded a track out, saved, and continued wrongly resumed the old
  in-place-volume-adjust behaviour on the very next same-name Play BGM
  instead of restarting it.
