- MZ (M6.3c): RPG Maker MZ now boots past `Scene_Boot` to a real scene. MZ's
  `Scene_Boot` readiness gates on promise-based, localforage-backed storage
  (`StorageManager.forageKeysUpdated`, `ConfigManager.load`,
  `DataManager.loadGlobalInfo`), which only settles once JS microtasks are
  drained between frames. The boot probe and run loop were hand-calling
  `SceneManager.update` and never pumping, so those promises never resolved and
  the boot stalled on `Scene_Boot`. Both now drive the engine through
  `MV::JS.pump` (the same mechanism MV uses) — firing MZ's
  requestAnimationFrame/ticker *and* draining microtasks each frame — so storage
  settles and the boot advances to a rendered scene.
