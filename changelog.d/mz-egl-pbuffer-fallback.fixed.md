- MZ (M6.3c): the off-screen EGL/GLES2 backend now falls back to a 1×1 pbuffer
  surface when a surfaceless `eglMakeCurrent` is rejected. RPG Maker MZ failed to
  boot in the native binary (`Utils.canUseWebGL()` returned false — the WebGL
  context could not be made current) because, under Xvfb with SDL up, the driver
  rejected binding the context with no surface, even though the headless
  `mruby_test` binary accepts it. The context renders into an FBO either way, so
  the pbuffer exists only to satisfy make-current; with it, MZ boots to
  Scene_Boot on the native binary as it does under Node.
