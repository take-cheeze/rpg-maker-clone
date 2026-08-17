- The main SDL window opens again on macOS instead of aborting on
  `Check failed: display` at startup. The `SDL_HINT_FRAMEBUFFER_ACCELERATION=0`
  workaround added for the X11 `GLXBadContext` crash (#449) only leaves a
  working fallback where the video backend implements a window framebuffer of
  its own — X11's XImage/MIT-SHM path, Wayland's `wl_shm` one, Emscripten's
  canvas one. SDL3's Cocoa backend has none, so `SDL_GetWindowSurface()` there
  can only go through `SDL_CreateWindowTexture`; turning that companion
  renderer off left it with nothing and `SDL_CreateRenderer()` failed with
  `Window framebuffer support not available`, taking the whole process down.
  The hint is now skipped on macOS, which keeps the #449 fix intact everywhere
  it actually helps.
