// Compile the M5Stack HAL into the firmware.
//
// The HAL lives in the mruby-rgss gem (mruby-rgss/src/m5stack.cxx) because in
// a full RGSS firmware it would be part of libmruby.a. For this bring-up build
// (which links no mruby) we pull the same source in directly via this one-line
// shim, which keeps every firmware source under src_dir -- portable, with no
// PlatformIO cross-directory src_filter tricks. m5stack.cxx self-guards on
// M5STACK_CORE. Mirrors app/wio/src/wio_hal.cxx.
#include "../../../mruby-rgss/src/m5stack.cxx"
