- **The PSP EBOOT now links end to end.** Once `libmruby.a` reached the final
  link step for the first time, three more platform gaps surfaced:
  - `umask` (backing `File.umask`) is an eighth POSIX symbol pspdev's newlib
    declares but does not implement -- added to `mruby-rgss/src/psp_io_stubs.c`
    alongside the six from the previous fix. Unlike those, `umask` cannot
    fail per POSIX, so it reports success (an always-0 mask) rather than
    `ENOSYS`.
  - `mruby-rgss`'s rake-driven compile (`mrbgem.rake`) never saw
    `app/psp/lv_conf.h` -- it always resolved LVGL's config through the
    shared `include/lv_conf.h` (`LV_USE_LOG 1`, `LV_USE_SNAPSHOT 1`) instead,
    while `app/psp/CMakeLists.txt`'s own LVGL build genuinely used
    `app/psp/lv_conf.h` (`LV_USE_LOG 0`). The two disagreeing about what
    `liblvgl.a` actually compiled in left `lib.cxx`'s calls to `lv_log_add`
    and `lv_snapshot_take` unresolved at link time. `mrbgem.rake` now puts
    `app/psp/`'s include directory ahead of the shared one for the `psp`
    build specifically, so both compiles see the same config.
  - `libpspkernel.a` bundles its own NID-stub implementations of a couple of
    libc functions (`strtol`, `strtoul`) alongside newlib's real ones, which
    collided as a hard "multiple definition" link error. Added
    `-Wl,--allow-multiple-definition` to the EBOOT's link options, which
    keeps the first (real, newlib) definition linked ahead of `libpspkernel.a`.
