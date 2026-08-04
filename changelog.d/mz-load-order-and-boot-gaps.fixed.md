- MZ (M6) foundation: corrected the `MZ::CORE_SCRIPTS` load order against the
  real engine's `main.js` — the Vorbis decoder is `js/libs/vorbisdecoder.js`,
  not `js/libs/vorbis.js` (guarded by a new spec in `mruby-mvjs/test/mz_test.rb`
  that also asserts no MV-only libs leak in). Documented the concrete,
  source-verified M6 boot-path gaps in ADR 0004 and `docs/TODO.md`: MZ's
  `main.js` is a dynamic `<script>`-injection loader (not MV's `window.onload`),
  it initialises an Effekseer WASM runtime before `Scene_Boot` (needs a WASM
  shim or a no-op stub), and the WebGL wall is precisely
  `SceneManager.run` → `Utils.canUseWebGL()` throwing without a real
  `getContext("webgl")` — turning "M6 needs WebGL" into an ordered work list.
