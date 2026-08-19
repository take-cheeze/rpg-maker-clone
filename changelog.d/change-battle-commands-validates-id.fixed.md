- **RPG2003 events:** Change Battle Commands (1009) now rejects a command
  id the database's own Battle Commands table doesn't define, matching
  RPG_RT. Previously any positive integer could occupy one of the six
  command slots regardless of whether it named a real entry, so a handful
  of stray invalid adds could silently starve a later, genuinely valid
  add of a slot it should have had.
