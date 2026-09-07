- The minimal RPG2000/2003 map-walking engine written for the iPod nano 7G
  (ADR 61) is now shared source (`app/shared/rpg2k_walk`) and runs on the
  **Wio Terminal** too: a new `wio_walk` PlatformIO environment reads a
  host-exported map off the board's microSD card and walks it on the LCD with
  the 5-way switch, linking neither LVGL nor mruby. That board could not run
  the real engine — 192 KB of SRAM against whole-file asset loading (ADR 7) —
  and this runs there because the LCF parsing, autotile assembly and chipset
  compositing already happened on the host. The exporter grew
  `--target nano7|wio`, which sizes an export for the target device's buffers
  and refuses a map that would not fit; the shared core has a host unit test
  (the `walk_core` ctest), the first automated coverage either firmware's
  device-side code has had. See ADR 91.
