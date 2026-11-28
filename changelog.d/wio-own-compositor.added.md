- **Wio Terminal draws without LVGL.** The Wio firmware draws through its
  own compositor (`mruby-rgss/src/gfx_own.cxx`): the same pixels (frame
  hashes match LVGL's), about 77 KB less internal flash, and no heap
  allocation of its own while drawing. Sprite zoom, rotation and
  add/subtract blending are drawn unscaled and normal there.
