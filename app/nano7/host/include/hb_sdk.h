/*
 * hb_sdk.h -- a VERIFIED SUBSET of NanoApps' sdk/hb_sdk.h
 * (nfzerox/NanoApps@80d439d), covering only the declarations
 * app/nano7/rpg2k_walk/rpg2k_walk.c and app/shared/rpg2k_walk/rpg2k_walk_core.c
 * actually reference. Every signature and macro below is copied from the
 * real file, not guessed (see docs/adr/0102, which follows ADR 94's own
 * "read the real source, don't assume" discipline) -- this is NOT a
 * reimplementation of the SDK's ~90-function surface, only the handful of
 * symbols this app's device source needs to compile and link.
 *
 * If rpg2k_walk.c ever calls another hb_sdk.h function, add it here from the
 * real header rather than approximating it.
 */
#ifndef HB_SDK_H_
#define HB_SDK_H_

#include <stdbool.h>
#include <stdint.h>

/* ---- Screen geometry ---- */

#define HB_SCREEN_W 240
#define HB_SCREEN_H 432

/* ---- Color ---- */

typedef uint32_t hb_color_t; /* 0x00RRGGBB, alpha unused */

#define HB_RGB(r, g, b) \
  ((((uint32_t)(r)) << 16) | (((uint32_t)(g)) << 8) | (uint32_t)(b))

#define HB_BLACK HB_RGB(0x00, 0x00, 0x00)
#define HB_WHITE HB_RGB(0xFF, 0xFF, 0xFF)

/* ---- ASCII text rendering (hb_font.c on the real device) ----
 *
 * app/nano7/host/nano7_host_shim.c's hb_draw_str is a deliberately
 * non-faithful placeholder (a blocky per-character rectangle, not the real
 * 8x8 glyph bitmap font in NanoApps' sdk/generated/hb_glyphs.c) -- it only
 * ever draws this app's "no map to walk" error screen, never the
 * map-rendering path this harness exists to check. See docs/adr/0102. */
void hb_draw_str(int16_t x,
                 int16_t y,
                 const char* s,
                 uint8_t scale,
                 hb_color_t fg,
                 hb_color_t bg);

/* ---- Filesystem (hb_fs.c on the real device) ---- */

/* Read up to `max_size` bytes from `path` into `buf`. Returns the
   number of bytes actually read (0 if file is missing or read failed). */
uint32_t hb_fs_read(const char* path, void* buf, uint32_t max_size);

/* ---- Uptime (hb_time.c on the real device) ---- */

uint32_t hb_time_uptime_ms(void);

#endif /* HB_SDK_H_ */
