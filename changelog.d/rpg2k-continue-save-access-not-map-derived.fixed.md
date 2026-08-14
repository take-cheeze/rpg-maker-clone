- **Continue could silently lose a save's own Save/Teleport/Escape access,
  overridden by whatever the current map's tree happens to say instead.**
  `Scene::Map#initialize` unconditionally re-derived all three access flags
  from the current map's tree property, which is correct for a fresh map
  entry (New Game, Transfer Player, Teleport) but wrong for a Continue,
  which resumes a state that already carries its own values restored from
  the save (set by a prior Change Save/Teleport/Escape Access event
  command). Verified under wine: the field-menu Save command on genuine
  `RPG_RT.exe` opened the real file-select screen on a save whose own
  `save_allowed` flag was on, on a map the tree itself flags
  Save-forbidden -- RPG_RT does not re-derive on Continue either.
  `Scene::Map.new` gained an `apply_access:` keyword (default true) and
  `RPG2k#continue_game` now passes `apply_access: false`, covering both the
  headless `--rpg2k_continue` path and the in-game Continue/Load screen.
