- MZ (M6.3c): the MZ boot smoke now runs with **no X server** — SDL's headless
  `dummy` video driver and a scrubbed `DISPLAY`/`XAUTHORITY` instead of Xvfb — so
  RPG Maker MZ boots to `Scene_Boot` through the off-screen WebGL backend.
  `Utils.canUseWebGL()` had returned false under Xvfb because, whenever an X
  server is reachable, Mesa dispatches even a surfaceless `eglMakeCurrent`
  through GLX to it and is denied (`X BadAccess` on `X_GLXMakeCurrent`) — while
  the headless `gl_test`, running the identical code with no X server, binds
  cleanly. With no X server the engine's renderer (surfaceless EGL over llvmpipe
  into an FBO) takes the same pure-software path and binds. The MZ probe never
  needs a visible window, so the `dummy` driver (which still satisfies LVGL's
  window requirement) is enough; `exe_open` and the other native smokes are
  unchanged (they keep using Xvfb). The backend also pins itself to software and
  hides `DISPLAY` around each EGL call (`ScopedSoftwareEGL`) as belt-and-braces.
