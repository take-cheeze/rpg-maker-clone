- **Wio Terminal: the GOTHIC (kanji) font's SD-card offload (previously
  opt-in, ADR 110) is now this target's default.** A plain
  `MRUBY_TARGET=wio rake` no longer compiles the ~165 KB JIS0208 kanji face
  into flash -- `build_config.rb` now sets `SHINONOME_GOTHIC_SD_FILE`/
  `RGSS_SHINONOME_GOTHIC_SD_PATH` itself (still overridable). Real relink:
  164,792 bytes of flash recovered for 1,040 bytes of RAM (a 64-slot lookup
  cache), still 46,384 bytes of RAM headroom left. A real SD deployment
  step that actually writes `gothic.bin` onto a card remains future work --
  see ADR 113.
