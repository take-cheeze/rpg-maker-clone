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

/*====================
   WIDGETS
 *====================*/

/* The bring-up firmware renders through base lv_obj containers and the lv_label
 * status screen; lv_canvas/lv_image are kept on to match the PSP config (the
 * same minimal set the RGSS runtime needs once mruby is layered on) rather than
 * churning this file per slice. Every other widget is dead weight on a 192 KB
 * board, so it is compiled out -- and each one is also dragged into the link by
 * the default theme's styles, so trimming here is what lets the linker drop it
 * (see THEMES below). */
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

/* No theme: the default theme is auto-initialised by lv_display_create and its
 * styles reference every widget, pulling all those object files into the link.
 * The firmware styles what it draws explicitly (lv_obj_set_style_*), so nothing
 * changes visually. */
#define LV_USE_THEME_DEFAULT 0
#define LV_USE_THEME_SIMPLE 0
#define LV_USE_THEME_MONO 0

/*====================
   LAYOUTS
 *====================*/

#define LV_USE_FLEX 0
#define LV_USE_GRID 0

/*====================
   OTHERS
 *====================*/

#define LV_USE_OBSERVER 0
#define LV_USE_OBJ_PROPERTY 0

/* clang-format on */

#endif  // LV_CONF_H
