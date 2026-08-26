- **Save/Load:** save files now match RPG_RT's real byte layout for two more
  fields. Control Save/Menu Access are written only when disabled (their own
  default is enabled), instead of unconditionally on every save. The save's
  own destination file slot now records the actual slot written to (present
  only for File 2 or later, matching RPG_RT's own default of File 1);
  previously it was hardcoded to File 1 regardless of which file the save
  actually went to.
