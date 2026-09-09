- **Wio Terminal: disabled three LVGL software-blend backends this build
  never selects** (1-bit canvases, byte-swapped RGB565, premultiplied-alpha
  ARGB8888) -- `lv_draw_sw_blend.c` links every format its `lv_conf.h`
  leaves enabled whether or not the firmware ever actually creates a layer
  in that format, since it's a runtime `switch`, not something the linker
  can prove dead on its own. Checked every real color-format call site in
  `mruby-rgss/src/lib.cxx`/`wio.cxx` first. Real relink: 23,616 bytes of
  flash recovered, no RAM cost. See ADR 114.
