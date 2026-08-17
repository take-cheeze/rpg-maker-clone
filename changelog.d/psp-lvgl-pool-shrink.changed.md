- **PSP: LVGL's memory pool cut from 4 MB to 256 KB.** ADR 0047's P2 already
  moved mruby's heap onto its own separate arena and established that decoded
  bitmaps never touch LVGL's pool; checking what was actually left for that
  pool to cover found the LVGL partial-render draw buffers don't either
  (`mruby-rgss/src/psp.cxx`'s `g_buf1`/`g_buf2` are plain `std::vector`, not
  `lv_malloc`'d) and the real game never reaches LVGL's own font/text system —
  every game screen draws through the RGSS `Bitmap`'s shinonome blitter,
  bypassing LVGL entirely. What the pool actually covers is `lv_obj_t`/style
  bookkeeping for the canvas/image/label widgets this port uses (already
  trimmed to those three), plausibly tens of KB even for a busy screen. 4 MB
  was never validated against anything; 256 KB is a comfortable multiple of
  that estimate, freeing ~3.75 MB of the PSP's ~24 MB budget.

  Because LVGL's own default `LV_ASSERT_HANDLER` (enabled here via
  `LV_USE_ASSERT_MALLOC`) is an unconditional `while(1);` — a silent halt
  indistinguishable from any other hang — `app/psp/lv_conf.h` now points it at
  a new `psp_lvgl_assert_halt` (`mruby-rgss/src/psp.cxx`), which writes a
  libc-free `RPG2K_PSP_LVGL_ASSERT` marker via `sceIoWrite` before halting, so
  a pool that turns out too small in practice is diagnosable from the log
  instead of an unexplained stall. Verified the shrunk pool builds clean and
  the idle-HAL screen (title + status label) does not trip that marker;
  validating it against a real game's widget count still needs an on-device
  run, same as the mruby arena's 8 MB figure.
