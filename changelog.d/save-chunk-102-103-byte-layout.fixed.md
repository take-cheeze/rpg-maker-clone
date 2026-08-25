- **Save/Load:** the screen-tint (chunk 102) and shown-pictures (chunk 103)
  sections of a save file now match RPG_RT's real byte layout: both
  containers are written on every save regardless of whether a tint or any
  picture is actually in use, the picture section always carries all 50
  RPG2000 picture slots (each individually empty when unused), and the
  tint section's own fields are each omitted independently when at their
  own default rather than as a single all-or-nothing block. Previously
  this engine omitted both containers entirely whenever neutral/empty and
  wrote the picture section as a sparse list of only ever-shown ids,
  producing saves with a different byte shape than a genuine RPG_RT save.
