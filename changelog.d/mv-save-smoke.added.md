- MV save smoke test: a new `--mv_save_test` flag drives the MV sample past New
  Game onto the map, then runs a save+load round-trip through the real
  `DataManager` — `saveGame` serializes the `$game*` objects into a slot via
  `StorageManager` (the host keeps `Utils.isNwjs()` false, so this goes through
  the localStorage shim that persists to disk), `StorageManager.exists` confirms
  the slot, and `loadGame` reads it back and rebuilds the game objects — logging
  `[MV-SAVE] saved=<bool> exists=<bool> loaded=<bool>`. It exercises the save
  path every game relies on, so CI confirms saves actually write and reload.
  Wired as a non-blocking `build` job step alongside the other MV smokes.
