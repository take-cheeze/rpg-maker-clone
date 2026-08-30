- **Saves:** a registered Set Teleport Target / Set Escape Target
  destination now survives a real Save/Continue, matching a reference
  implementation's own save-data handling, not independently confirmed
  against genuine RPG_RT under wine -- it previously round-tripped
  through this engine's own in-memory save format but silently vanished
  the moment a genuine `.lsd` save was reloaded, even though the
  Escape/Teleport skills already read it live.
