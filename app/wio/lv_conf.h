// LVGL configuration for the Wio Terminal firmware.
//
// A deliberately small, embedded-tuned config -- the desktop build's
// include/lv_conf.h hardcodes a 16 MB LVGL heap pool, which cannot exist on the
// board's 192 KB SRAM. LVGL v9 fills every option not set here with the default
// from lv_conf_internal.h, so this only overrides what the board needs.
//
// Selected via -DLV_CONF_INCLUDE_SIMPLE plus this directory on the include path
// (see platformio.ini).

#ifndef LV_CONF_H
#define LV_CONF_H

/* clang-format off */

#include <stdint.h>

/*====================
   COLOR / MEMORY
 *====================*/

#define LV_COLOR_DEPTH 16

/* Built-in allocator with a small static pool. The whole firmware -- LVGL
 * objects, the draw buffers in wio.cxx, the stack, and (later) the mruby heap
 * -- shares 192 KB, so keep this modest. */
#define LV_USE_STDLIB_MALLOC  LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_STRING  LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_SPRINTF LV_STDLIB_BUILTIN
#define LV_MEM_SIZE (40 * 1024U)

/*====================
   HAL / TICK
 *====================*/

/* The tick comes from Arduino millis() via lv_tick_set_cb() in wio.cxx. */
#define LV_USE_OS LV_OS_NONE

/*====================
   RENDERING
 *====================*/

#define LV_USE_DRAW_SW 1
#define LV_DRAW_SW_DRAW_UNIT_CNT 1

/*====================
   LOGGING / ASSERTS
 *====================*/

#define LV_USE_LOG 0
#define LV_USE_ASSERT_NULL 1
#define LV_USE_ASSERT_MALLOC 1

/*====================
   FONTS
 *====================*/

#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_DEFAULT &lv_font_montserrat_14

/*====================
   DRIVERS
 *====================*/

/* The panel is driven directly by Seeed_Arduino_LCD from wio.cxx's flush
 * callback, so LVGL's own display drivers stay off. */
#define LV_USE_SDL 0

/* clang-format on */

#endif  // LV_CONF_H
