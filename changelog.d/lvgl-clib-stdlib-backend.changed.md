- **Wio Terminal: LVGL now shares mruby's own heap instead of reserving a
  separate 40 KB static memory pool.** `app/wio/lv_conf.h` switched
  `LV_USE_STDLIB_MALLOC`/`STRING`/`SPRINTF` from LVGL's built-in
  allocator/string/formatter implementations to its `LV_STDLIB_CLIB`
  backend, which points them at the same `malloc`/`free`/string functions
  mruby's GC already links in on every build. Real relink: RAM headroom
  goes from 6,440 to 47,424 bytes (of a 196,608-byte budget) -- the biggest
  single RAM win found this round, on a board that had none to spare -- and
  flash overflow drops by a further 2,440 bytes. See ADR 112.
