- **Investigated moving all of `mruby-rpg2k`'s compiled Ruby to the SD card
  for the Wio Terminal build**, loaded back in via `mrb_load_irep_buf` (the
  gem carries no native code of its own). Proved the mechanism works end to
  end on the host (a real 676,583-byte standalone `.mrb`, compiled from the
  gem's own 17 files, loads into a shared-gems-only interpreter and defines
  real, usable classes) and that it would recover 600,752 bytes of the
  board's flash overflow — but a real relink shows the board still overflows
  flash by 510,340 bytes with *zero* rpg2k Ruby compiled in at all, so this
  is not a fix by itself: the interpreter/RGSS/LVGL skeleton is now the
  dominant remaining cost, and no loading granularity (whole-gem or
  scene-level) changes that floor. See ADR 108. The opt-in
  `RGSS_WIO_EXTERNAL_RPG2K` env var this added to `mruby-rpg2k/mrbgem.rake`
  is a no-op unless set and not wired into any real build.
