- The main window (RPG2000/2003, XP, VX(Ace) and MV all share it) now sets
  `SDL_HINT_RENDER_DRIVER=software` before opening its SDL window, so it
  never probes an OpenGL/GLX render driver. `lv_conf.h` already asked LVGL's
  SDL backend for `SDL_RENDERER_SOFTWARE` (`LV_SDL_ACCELERATED 0`), and only
  MZ's WebGL backend needs a real GL context — a wholly separate off-screen
  EGL context in `mruby-mvjs/src/mvgl.cxx`, never this window — but the hint
  makes the guarantee explicit rather than implicit, so the engine keeps
  working on an X server with no OpenGL support at all (#449).
