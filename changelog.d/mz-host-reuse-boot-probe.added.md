- MZ (M6.2): the RPG Maker MZ path now reuses the shared quickjs host to drive
  the real `rmmz_*` engine up to the renderer boundary. `MZ#boot_probe` loads the
  engine scripts (skipping MZ's `main.js` dynamic loader and the WASM-gated,
  audio-only `vorbisdecoder.js`), installs the `HTMLVideoElement`/
  `HTMLImageElement` host globals `rmmz_managers.js` requires, and runs
  `SceneManager.run(Scene_Boot)`, which reaches exactly `Utils.canUseWebGL()`
  in `rmmz_managers.js` and stops — proving everything up to WebGL works. The
  pure logic (`MZ.runnable_scripts`, `MZ.host_globals_js`) is covered by host
  specs; the full boot is verified against a user-supplied MZ project since MZ's
  engine has no open-source release to commit. ADR 0004 and `docs/TODO.md` now
  carry the measured boot map, correcting the earlier source-read guess that the
  Effekseer WASM init blocked the boot (it does not — it lives in the bypassed
  `main.js`).
