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

/* LV_STDLIB_BUILTIN (the default) reserves its own static LV_MEM_SIZE pool
 * in .bss up front, on top of newlib's own malloc that mruby's GC already
 * links in regardless of this setting -- two heaps, one of them a fixed
 * size whether LVGL uses it or not. CLIB instead points lv_malloc/
 * lv_free/lv_snprintf/string ops straight at the already-linked libc
 * versions, so this board's minimal canvas/image/label usage draws from
 * the same dynamic heap mruby uses instead of a second, statically-sized
 * one. See docs/adr/0112. */
#define LV_USE_STDLIB_MALLOC  LV_STDLIB_CLIB
#define LV_USE_STDLIB_STRING  LV_STDLIB_CLIB
#define LV_USE_STDLIB_SPRINTF LV_STDLIB_CLIB

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

/* lv_draw_sw_blend.c dispatches on a *destination layer's* own color format
 * with a runtime switch -- every case it compiles in gets linked whether or
 * not this firmware ever actually creates a layer in that format, since the
 * linker can only prove a whole function/case unreachable, not a specific
 * enum value. Checked against every real call site (RGSS::Bitmap always
 * backs its canvases with LV_COLOR_FORMAT_ARGB8888 or, for opaque 3-channel
 * decoded images, RGB888 -- mruby-rgss/src/lib.cxx; the display itself is
 * plain RGB565, wio.cxx's own lv_display_set_color_format call, no swap).
 * I1 (1-bit canvases), byte-swapped RGB565, and premultiplied-alpha ARGB8888
 * are never requested by any of that, so their backends are pure dead
 * weight here -- unlike A8/L8/AL88 (LVGL's own font-glyph and image-mask
 * decoding paths reach those internally, confirmed by grepping
 * 3rd/lvgl/src for each format outside this dispatcher) or RGB888/ARGB8888/
 * RGB565 (all three used directly above). See docs/adr/0114. */
#define LV_DRAW_SW_SUPPORT_I1 0
#define LV_DRAW_SW_SUPPORT_RGB565_SWAPPED 0
#define LV_DRAW_SW_SUPPORT_ARGB8888_PREMULTIPLIED 0

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

/* lv_canvas/lv_image are the only widgets the real RGSS runtime needs (Sprite/
 * Viewport/Bitmap render through them) and are kept on to match the PSP
 * config. LV_USE_LABEL looked droppable too -- neither bring-up screen's own
 * status/key echo (rewritten to a background-color signal + Serial output,
 * docs/adr/0132) nor the real RGSS render path (which renders game text
 * through this project's own shinonome/cp932 pipeline, never LVGL's) calls
 * lv_label_* any more -- but LV_USE_IMAGE itself hard-requires it: LVGL's own
 * lv_image.h #errors at compile time ("lv_img: lv_label is required") when
 * LV_USE_LABEL is off, confirmed by a real MRUBY_TARGET=wio build. Sprite/
 * Viewport zoom and rotation genuinely need lv_image, so this stays on as a
 * forced dependency, not a measurement oversight. Every other widget is dead
 * weight on a 192 KB board, so it is compiled out -- and each one is also
 * dragged into the link by the default theme's styles, so trimming here is
 * what lets the linker drop it (see THEMES below). */
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
