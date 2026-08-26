- **Save/Load:** an Erase Picture'd id now matches RPG_RT's real save-file
  behavior -- the picture stops drawing and can't be moved, but its saved
  position, zoom, opacity and tone keep the exact values it held at the
  moment of erasure, with only its name recorded as absent. Previously
  erasing a picture also dropped these fields entirely, indistinguishable
  from an id that had never been shown at all.
