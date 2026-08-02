// Compile the Wio HAL into the firmware.
//
// The HAL lives in the mruby-rgss gem (mruby-rgss/src/wio.cxx) because in the
// full firmware it is part of libmruby.a. For this bring-up build (which links
// no mruby) we pull the same source in directly via this one-line shim, which
// keeps every firmware source under src_dir -- portable, with no PlatformIO
// cross-directory src_filter tricks. wio.cxx self-guards on WIO_TERMINAL.
#include "../../../mruby-rgss/src/wio.cxx"
