// Compile the M5Stack HAL into the firmware.
//
// The HAL lives in the mruby-rgss gem (mruby-rgss/src/m5stack.cxx) because in
// a full RGSS firmware it would be part of libmruby.a. For this bring-up build
// (which links no mruby) we pull the same source in directly via this
// one-line shim instead, which keeps this project's own src/ directory (this
// is a standalone PlatformIO project rooted at app/m5stack -- see that
// directory's own platformio.ini and README.md for why) self-contained.
// m5stack.cxx self-guards on M5STACK_CORE. Mirrors app/wio/src/wio_hal.cxx.
#include "../../../mruby-rgss/src/m5stack.cxx"
