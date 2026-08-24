- **Android:** the boot abort (`CHECK(display)` right after
  `lv_sdl_window_create`) is fixed: Android's SDL video backend never
  implements a native `CreateWindowFramebuffer`, so `SDL_GetWindowSurface()`
  can only go through the GL-texture path that the desktop #449 workaround
  (`SDL_HINT_FRAMEBUFFER_ACCELERATION=0`) switches off. That hint is now kept
  off Android, as it already was for macOS/Cocoa.
