- **RPG2003's "Death Handler" is now implemented.** A wandering-monster
  encounter's party wipe used to always end the game outright; when the
  database's `System > Battle Commands > Death Handler` setting is active,
  it now runs the configured common event and/or teleports the party
  instead, matching real RPG_RT.
