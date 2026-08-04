- MZ (M6.3c): the off-screen EGL/GLES2 backend now pins itself to the
  pure-software surfaceless path and cuts off any route to an X server while it
  binds, so RPG Maker MZ can boot in the native binary under Xvfb.
  `Utils.canUseWebGL()` had returned false there: with `DISPLAY` set (the binary
  runs under `xvfb-run`), Mesa dispatched even a surfaceless `eglMakeCurrent`
  through GLX to the X server, which denied it (`X BadAccess` on
  `X_GLXMakeCurrent`) — while the headless `gl_test`, running the identical code
  with no X server at all, binds cleanly. Around each EGL call the backend now
  unsets `DISPLAY` and `XAUTHORITY` and forces `EGL_PLATFORM=surfaceless` /
  `GALLIUM_DRIVER=llvmpipe` / `LIBGL_ALWAYS_SOFTWARE=1`, reproducing that
  headless environment; the surfaceless bind (with a 1×1-pbuffer and explicit
  software-device fallback) then succeeds off-screen into an FBO. The backend
  stays lazy — only a WebGL `getContext` triggers it — so non-WebGL games (the
  RPG2k `exe_open` smoke) never touch GL.
