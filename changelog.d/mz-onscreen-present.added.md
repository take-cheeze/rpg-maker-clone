- MZ (M6.3c): RPG Maker MZ now presents its rendered frames on-screen, not just
  booting to `Scene_Boot`. `MZ.runtime_available?` is on wherever the WebGL
  backend is compiled (`MV::GL`), so — like MV — `MZ#start` boots the engine
  once and then runs a per-frame loop: `SceneManager.update` renders the scene
  through PIXI v5 into the WebGL canvas, `MZ#present` blits that frame (via
  `MV::JS.present_gl`, reading the context's FBO) onto a full-screen
  `RGSS::Sprite`/`Bitmap`, and `RGSS::Graphics.update` draws it — mirroring MV's
  present path. The boot still logs `[MZ-BOOT] booted to Scene_Boot` and, if
  WebGL cannot be made current (e.g. under an X server, where Mesa rejects the
  bind), reports the boundary instead of spinning. Input is the remaining piece
  before MZ is fully playable.
