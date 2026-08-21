- **Saves:** a registered Set Teleport Target / Set Escape Target
  destination now survives a real Save/Continue, matching RPG_RT's
  `Game_Targets::GetSaveData`/`SetSaveData` -- it previously round-tripped
  through this engine's own in-memory save format but silently vanished
  the moment a genuine `.lsd` save was reloaded, even though the
  Escape/Teleport skills already read it live.
