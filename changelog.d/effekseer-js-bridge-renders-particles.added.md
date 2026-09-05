- `MZ::EFFEKSEER_SHIM_JS`'s `init`/`beginDraw`/`drawHandle`/`endDraw`/
  `setProjectionMatrix`/`setCameraMatrix` (previously no-ops) now route to a
  real `EffekseerRendererGL::Renderer`, attached to the exact native GL
  context backing `Graphics._app.renderer.gl` via a new
  `mv_webgl_make_current` (`mruby-mvjs/src/mvwebgl.cxx`) resolving the
  WebGLRenderingContext's own handle -- so real MZ animations now draw real,
  visible particles through PIXI's own WebGL context, not just simulate.
  Fixed one real gap found while proving this: effect loading never passed
  Effekseer a `materialPath`, so every texture/model/material a real effect
  references silently failed to resolve and it drew nothing despite
  simulating correctly; `effect_load` now derives it from the effect's own
  game-relative path (`mruby-mvjs/src/mvefk.cxx`). Verified with real pixel
  evidence (not just a code path that ran): a new mrbtest drives the exact
  call sequence `Sprite_Animation._render` uses against a real, unmodified
  `.efkefc` and confirms real pixels change. Every pre-existing shim test
  (synthetic/malformed-content fallback) passes unchanged.
