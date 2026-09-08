- **A real PlatformIO link of the Wio Terminal's mruby+RGSS+LVGL stack now
  succeeds with zero undefined symbols**, for the first time — the still-
  missing piece ADR 103 named. Fixed a chain of real ABI/toolchain mismatches
  that only a genuine end-to-end link surfaced: the measurement-only Arduino/
  TFT_eSPI header stub was silently ABI-incompatible with a real link (wrong
  parameter types, missing `extern "C"`, and a `TFT_eSPI` global with the
  wrong object layout entirely), replaced by a new escape hatch that compiles
  against the real PlatformIO framework headers; the mruby cross build was
  quietly using the wrong `arm-none-eabi-gcc` (a distro package via `PATH`
  instead of PlatformIO's own bundled toolchain); GCC's thread-safe static-
  variable guards needed `-fno-threadsafe-statics` (PlatformIO's own Arduino
  framework already builds with it, for the same reason); C++17 needed an
  explicit `-std=gnu++17` (PlatformIO's bundled compiler defaults to
  `gnu++14`); `mruby-io`'s `file.c` doesn't compile on this board's newlib at
  all without a `MAXPATHLEN` fallback patch; and PlatformIO's own Arduino
  builder never links `libstdc++`, which this engine's C++ code genuinely
  needs. The link now fails only on flash/RAM size (flash overflows by
  ~3.4x) — a real, tractable follow-up, not a correctness problem. See
  ADR 104.
