- MZ (M6.3c): RPG Maker MZ now boots to `Scene_Boot` through the WebGL renderer.
  `data/mz-sample` is a new test-bed — a minimal authored database (committed) +
  the rmmz engine fetched at build time by `scripts/download-mz-corescript.bash`
  (community mirror, a CI-only fixture, never committed, like the RPG2k/XP game
  downloads). `MZ` gains the one host global MZ's boot needs beyond MV's —
  `indexedDB` (the `SceneManager.checkBrowser` guard that runs right after
  `Utils.canUseWebGL`, which the WebGL backend now passes) — and `MZ#boot_probe`
  drives `SceneManager.run(Scene_Boot)` plus a few frames past the old WebGL
  wall: `Graphics` builds the PIXI v5 renderer on the surfaceless-EGL GLES2
  backend and the scene renders. `scripts/mz_boot_check.bash` asserts the
  `[MZ-BOOT] booted to <scene>` marker in CI. The gap set was discovered and the
  authored database validated by booting PIXI v5.2.4 + rmmz under Node against
  the wrapper's method surface, including through rmmz's real `DataManager`.
  Continuous play (per-frame on-screen present, input) is the remaining work.
