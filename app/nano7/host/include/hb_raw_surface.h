/*
 * hb_raw_surface.h -- verbatim copy of NanoApps' sdk/hb_raw_surface.h
 * (nfzerox/NanoApps@80d439d). See docs/adr/0102: this host build links
 * app/nano7/rpg2k_walk/rpg2k_walk.c unmodified, so its declarations must
 * match the real header exactly. The "implement these in the app" functions
 * are rpg2k_walk.c's own; the "runtime API" functions are implemented by
 * app/nano7/host/nano7_host_shim.c instead of the real NanoApps resident.
 */
#ifndef HB_RAW_SURFACE_H
#define HB_RAW_SURFACE_H

#include <stdint.h>
#include "hb_surface_input.h"

/* ---- implement these in the app ---- */
void hb_raw_init(int w, int h);                /* set up state + draw the first frame */
void hb_raw_frame(const hb_spoint_t *touch);   /* called each heartbeat (~60 fps)     */

/* ---- runtime API ---- */
uint32_t *hb_raw_fb(void);    /* the framebuffer (XRGB8888, w*h, row-major) */
int       hb_raw_w(void);
int       hb_raw_h(void);

/* Direct-draw helpers. Color is 0xRRGGBB (alpha forced opaque -- the compositor
 * wants XRGB). All clip to the framebuffer. */
void hb_raw_fill(uint32_t rgb);                              /* whole framebuffer    */
void hb_raw_fill_rect(int x, int y, int w, int h, uint32_t rgb);
void hb_raw_rect_outline(int x, int y, int w, int h, int t, uint32_t rgb);
void hb_raw_disc(int cx, int cy, int r, uint32_t rgb);      /* filled circle (brush) */
void hb_raw_blit(int x, int y, int w, int h, const uint32_t *src);   /* opaque copy  */

#endif /* HB_RAW_SURFACE_H */
