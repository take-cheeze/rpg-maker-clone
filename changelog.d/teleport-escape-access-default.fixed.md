- **Save data:** Teleport and Escape access (the flags the "Enable/Disable
  Teleport" and "Enable/Disable Escape" event commands toggle) now default to
  **allowed**, matching genuine RPG_RT.exe. Previously a new game started
  with both forbidden until an event explicitly enabled them, and a saved
  game where they had simply never been touched could load back with them
  wrongly forbidden instead of allowed. Save files also now only record
  these two flags when they differ from that allowed default, the same way
  Save/Menu access already did, instead of always writing a value.
