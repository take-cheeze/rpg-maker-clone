- **Wio Terminal: own compositor (`WIO_GFX=own`).** The Wio build can draw
  through `mruby-rgss/src/gfx_own.cxx` instead of LVGL: the same pixels (frame
  hashes match LVGL's), about 77 KB less internal flash, and no heap
  allocation of its own while drawing. LVGL stays the default.
