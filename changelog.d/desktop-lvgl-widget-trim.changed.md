- **Desktop LVGL config now matches the embedded builds.** `include/lv_conf.h`
  compiles out every widget beyond the RGSS layer's real set
  (canvas/image/label), the three default themes, and the flex/grid layouts —
  the default theme is what `lv_display_create` auto-installs and whose styles
  reference every widget, so disabling it lets the linker drop the unused
  widget object files. The root `CMakeLists.txt` also stops building LVGL's
  examples/demos (PUBLIC-linked into `liblvgl.a` by default), the same
  `CONFIG_LV_BUILD_EXAMPLES/DEMOS OFF` as `app/psp` — set as cache variables
  because LVGL's `option()` only honours cache variables with CMP0077 unset.
  All three targets now compile the same minimal LVGL, so the render path
  cannot drift between desktop and the embedded builds. See
  `docs/adr/0047-psp-memory-budget.md`.
