// LVGL configuration for the PSP EBOOT.
//
// The desktop build's include/lv_conf.h hardcodes a 64 MB LVGL heap pool, which
// does not fit the PSP's ~24 MB of user RAM once mruby and game assets are
// added later. This config keeps the same shape but a PSP-sized heap. LVGL v9
// fills every option not set here with the default from lv_conf_internal.h, so
// this only overrides what the port needs.
//
// Selected via -DLV_CONF_INCLUDE_SIMPLE plus this directory on the include path
// (see app/psp/CMakeLists.txt). The same config is seen by the psp mruby
// cross-build that compiles mruby-rgss (mruby-rgss/mrbgem.rake adds this dir to
// its include path when build.name == 'psp'), so the two agree on what LVGL
// compiled in.

#ifndef LV_CONF_H
#define LV_CONF_H

/* clang-format off */

#include <stdint.h>

/*====================
   COLOR / MEMORY
 *====================*/

/* RGB565, matching the display framebuffer set up in psp.cxx. */
#define LV_COLOR_DEPTH 16

/* Built-in allocator with a static pool. Covers only LVGL's own widgets and
 * internals: mruby's heap lives in its own fixed arena (app/psp/main.cxx's
 * mrb_basic_alloc_func, ADR 0047's P2) and decoded bitmaps in the plain C
 * heap, so this pool no longer needs to double as mruby's. 4 MB is generous
 * for the widget tree alone; the BRINGUP heartbeat's lvgl_max high-water mark
 * is the number to size it against on-device. */
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

/*====================
   WIDGETS
 *====================*/

/* The RGSS runtime renders through lv_canvas (every Bitmap is a canvas buffer)
 * and base lv_obj containers; the idle bring-up status screen uses lv_label and
 * lv_image is a canvas dependency. Every other widget is dead weight on the
 * PSP: the whole EBOOT is loaded into RAM at launch, so a widget file that is
 * compiled in is RAM-resident for the process lifetime, not just flash. Each
 * unused widget is also dragged into the link by the default theme's styles
 * (see THEMES below), so trimming here is what actually lets the linker drop
 * them. */
#define LV_USE_CANVAS     1
#define LV_USE_IMAGE      1
#define LV_USE_LABEL      1

#define LV_USE_ANIMIMG    0
#define LV_USE_ARC        0
#define LV_USE_ARCLABEL   0
#define LV_USE_BAR        0
#define LV_USE_BUTTON     0
#define LV_USE_BUTTONMATRIX 0
#define LV_USE_CALENDAR   0
#define LV_USE_CHART      0
#define LV_USE_CHECKBOX   0
#define LV_USE_DROPDOWN   0
#define LV_USE_IMAGEBUTTON 0
#define LV_USE_KEYBOARD   0
#define LV_USE_LED        0
#define LV_USE_LINE       0
#define LV_USE_LIST       0
#define LV_USE_MENU       0
#define LV_USE_MSGBOX     0
#define LV_USE_ROLLER     0
#define LV_USE_SCALE      0
#define LV_USE_SLIDER     0
#define LV_USE_SPAN       0
#define LV_USE_SPINBOX    0
#define LV_USE_SPINNER    0
#define LV_USE_SWITCH     0
#define LV_USE_TABLE      0
#define LV_USE_TABVIEW    0
#define LV_USE_TEXTAREA   0
#define LV_USE_TILEVIEW   0
#define LV_USE_WIN        0

/*====================
   THEMES
 *====================*/

/* No theme at all: the default theme is auto-initialised by lv_display_create
 * (LV_USE_THEME_DEFAULT) and its styles reference every widget, which is what
 * pulls all those widget object files into the link in the first place. The
 * RGSS runtime styles every object it creates explicitly (lv_obj_remove_style_all
 * + lv_obj_set_style_*), so dropping the theme changes nothing for the game
 * path -- labels on the idle status screen set their own text colour too. */
#define LV_USE_THEME_DEFAULT 0
#define LV_USE_THEME_SIMPLE 0
#define LV_USE_THEME_MONO 0

/*====================
   LAYOUTS
 *====================*/

/* The RGSS runtime positions objects with lv_obj_align / lv_obj_set_pos, never
 * flex/grid layouts. */
#define LV_USE_FLEX 0
#define LV_USE_GRID 0

/*====================
   OTHERS
 *====================*/

/* The RGSS runtime neither observes nor reads objects via the property API. */
#define LV_USE_OBSERVER 0
#define LV_USE_OBJ_PROPERTY 0

/* clang-format on */

#endif  // LV_CONF_H
