- **Saves:** a live Change Encounter Rate override now survives a real
  Save/Continue, matching RPG_RT's `SaveMapInfo.encounter_steps` -- it
  previously round-tripped through this engine's own in-memory save
  format but silently reverted to the map's own default rate the moment
  a genuine `.lsd` save was reloaded.
