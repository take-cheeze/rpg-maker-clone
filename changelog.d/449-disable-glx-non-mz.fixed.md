- The main window (RPG2000/2003, XP, VX(Ace) and MV all share it) no longer
  crashes with a fatal `X_GLXMakeCurrent` (`GLXBadContext`) error on an X
  server with no working GLX. `include/lv_conf.h` already asks LVGL's SDL
  backend for `SDL_RENDERER_SOFTWARE` (`LV_SDL_ACCELERATED 0`), but on SDL3
  (reached here via sdl2-compat) that software renderer still calls
  `SDL_GetWindowSurface()` to present, and that spins up a *second*,
  GPU-accelerated companion renderer to blit it (`SDL_CreateWindowTexture`)
  that ignored the driver choice and tried `opengl` first. The window now
  also sets `SDL_HINT_FRAMEBUFFER_ACCELERATION=0` before opening, so that
  companion renderer is never created and the window falls back to a plain
  CPU blit — only MZ's WebGL backend needs a real GL context, and that is a
  wholly separate off-screen EGL context in `mruby-mvjs/src/mvgl.cxx`,
  unaffected by this (#449).
