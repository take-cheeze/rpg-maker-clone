- **Android gameplay FPS: 22 → 60 on the title screen, 2x in map scenes.**
  Three present-path fixes measured on-device (C330, arm64-v8a, Nepheshel):
  LVGL's SDL backend now creates an *accelerated* renderer there
  (`LV_SDL_ACCELERATED 1` under `__ANDROID__`; desktop keeps the software
  renderer) so the GPU does the window stretch and swap instead of a
  per-frame CPU blit of the whole surface — the flush fell from ~63ms to
  ~5ms a frame; the display refresh period drops to one game frame (16ms)
  on Android, un-capping the picture at the stock 33ms (~25fps) whatever
  the render cost; and the virtual-pad shell fits the display zoom to the
  game's own height (`src/android_vpad_ui.cxx`), so LVGL software-rasters
  the game picture 1:1 and the GPU stretches it to the phone window instead
  of rastering 2.8x its pixels. The pad now overlaps the picture's edges
  (translucently) where the old layout had it in the letterbox bands.
