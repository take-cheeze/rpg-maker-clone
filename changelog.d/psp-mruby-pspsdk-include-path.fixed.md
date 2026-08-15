- **The `psp` mruby cross-build now finds pspsdk's own headers.** Now that
  `mruby-rgss/src/psp.cxx` (the real LVGL/pad HAL, `PSP_BUILD`-gated) compiles
  as part of `libmruby.a` instead of being compiled directly by CMake,
  `#include <pspctrl.h>` and friends failed with "No such file or directory":
  `psp-cmake`'s toolchain file adds pspsdk's include path to CMake's own
  compiles automatically, but `build_config.rb`'s `psp` `MRuby::CrossBuild`
  drives `psp-gcc`/`psp-g++` directly through mruby's own rake-based build
  and got none of that. `psp-config --pspsdk-path` (pspsdk's own discovery
  tool, the same one Makefile-based pspsdk projects use) now supplies the
  path instead.
