/* Compile the shared map-walk core into the wio_walk firmware.
 *
 * The core is platform-independent C shared with the iPod nano 7G app
 * (app/shared/rpg2k_walk/rpg2k_walk_core.c, docs/adr/0091). This one-line
 * shim keeps every firmware source under src_dir -- portable, with no
 * PlatformIO cross-directory src_filter tricks -- exactly as wio_hal.cxx
 * does for the LVGL HAL that lives in the mruby-rgss gem. */
#include "../../shared/rpg2k_walk/rpg2k_walk_core.c"
