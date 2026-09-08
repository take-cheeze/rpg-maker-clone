- **The Wio Terminal's `MRUBY_TARGET=wio` mruby cross build compiles and
  archives for real now** — the first time in this project's history it has
  been run to completion. Fixed four real, previously-undiscovered bugs that
  blocked it: no HAL for `mruby-io` on this board's bare `arm-none-eabi`
  newlib (a new `hal-wio-io` gem, implementing exactly the file operations a
  real RPG2000/2003 game reaches through this exporter's own file access);
  `mruby-dir` pulled in unconditionally despite nothing on this target ever
  using `Dir`; the `WIO_TERMINAL` macro that gates the real LVGL HAL on and
  the desktop-only terminal backend off was never actually defined for this
  build; and `mruby-marshal` silently defeated ADR 98's own onigmo trim for
  psp/wio via an unconditional gem dependency (fixed together with a real
  safety gap it depended on unknowingly: `Marshal.dump`/`.load` no longer
  hard-require the `Regexp` class, which only onigmo defines, to exist at
  all). No real flash/RAM number yet — that needs LVGL/uni-algo cross-built
  for ARM and a real PlatformIO link, still future work. See ADR 103.
