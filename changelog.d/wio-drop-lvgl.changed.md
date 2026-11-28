- **Wio Terminal draws without LVGL.** The Wio firmware always uses the own
  compositor (`mruby-rgss/src/gfx_own.cxx`) and no longer links LVGL, which
  frees about 77 KB of internal flash. `WIO_GFX` is gone.
