// LVGL configuration for the PSP EBOOT.
//
// The desktop build's include/lv_conf.h hardcodes a 16 MB LVGL heap pool, which
// does not fit the PSP's ~24 MB of user RAM once mruby and game assets are added
// later. This config keeps the same shape but a PSP-sized heap. LVGL v9 fills
// every option not set here with the default from lv_conf_internal.h, so this
// only overrides what the port needs.
//
// Selected via -DLV_CONF_INCLUDE_SIMPLE plus this directory on the include path
// (see app/psp/CMakeLists.txt).

#ifndef LV_CONF_H
#define LV_CONF_H

/* clang-format off */

#include <stdint.h>

/*====================
   COLOR / MEMORY
 *====================*/

/* RGB565, matching the display framebuffer set up in psp.cxx. */
#define LV_COLOR_DEPTH 16

/* Built-in allocator with a static pool. Comfortable on the PSP's RAM, but far
 * from the desktop's 16 MB so it leaves room for the mruby heap and whole-file
 * assets in later slices. */
#define LV_USE_STDLIB_MALLOC  LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_STRING  LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_SPRINTF LV_STDLIB_BUILTIN
#define LV_MEM_SIZE (4 * 1024U * 1024U)

/*====================
   HAL / TICK
 *====================*/

/* The tick comes from the pspsdk system timer via lv_tick_set_cb() in psp.cxx. */
#define LV_USE_OS LV_OS_NONE

/*====================
   RENDERING
 *====================*/

#define LV_USE_DRAW_SW 1
#define LV_DRAW_SW_DRAW_UNIT_CNT 1

/* The Allegrex has neither NEON nor Helium; keep LVGL's hand-written SIMD blend
 * kernels off so its CMake never tries to assemble them for MIPS. */
#define LV_USE_DRAW_SW_ASM LV_DRAW_SW_ASM_NONE

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

/* The panel is driven directly from psp.cxx's flush callback (sceDisplay), so
 * LVGL's own display drivers stay off. */
#define LV_USE_SDL 0

/* clang-format on */

#endif  // LV_CONF_H
