- `MZ::EFFEKSEER_SHIM_JS`'s `loadEffect`/`play`/`update`/`stopAll` now route
  through a real, persistent `Effekseer::Manager` (new `__mv_efk*` natives,
  `mruby-mvjs/src/mvefk.cxx`) wherever the loaded `.efkefc` file genuinely
  parses, so `handle.exists`/animation timing reflect the effect's own
  authored duration instead of an arbitrary placeholder. A synthetic or
  malformed effect (as this project's own pre-existing tests deliberately
  use) still falls back to the original fixed-lifetime handle unchanged, so
  nothing that worked before behaves differently now. Still doesn't draw
  particles through this path: only simulation is wired, not
  `EffekseerRendererGL::Renderer` -- rendering needs to share the exact GL
  context/FBO PIXI's own WebGL renderer is using mid-frame, staged as its
  own follow-up.
