- **Save/Continue:** a live Change Parameters edit to an actor's Max HP/MP or
  ATK/DEF/SPI/AGI now survives a real save/load, matching RPG_RT -- previously
  it silently reverted to the bare level-curve value the instant the save
  reloaded, even though this same adjustment already round-tripped correctly
  through this engine's own portable save format.
