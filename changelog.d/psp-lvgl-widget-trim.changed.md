- **PSP/Wio: LVGL is trimmed to the widgets the runtime actually uses.** The
  EBOOT's `app/psp/lv_conf.h` (and the Wio firmware's `app/wio/lv_conf.h`)
  now compile out every widget beyond the RGSS layer's real set
  (canvas/image/label), the three default themes, and the flex/grid layouts —
  the default theme is what `lv_display_create` auto-installs and whose styles
  reference every widget, so disabling it is what lets the linker drop the
  unused widget object files. The PSP EBOOT also stops linking LVGL's
  examples/demos (`CONFIG_LV_BUILD_EXAMPLES/DEMOS OFF` in
  `app/psp/CMakeLists.txt`), which its CMake PUBLIC-links into `liblvgl.a` by
  default. On the PSP every byte of the EBOOT is loaded into RAM at launch, so
  this is live memory, not just flash. See `docs/adr/0047-psp-memory-budget.md`.
