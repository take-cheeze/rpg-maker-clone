/*
 * hb_surface_input.h -- verbatim copy of NanoApps' sdk/hb_surface_input.h
 * (nfzerox/NanoApps@80d439d), the touch-state struct every surface runtime
 * (hb_raw_surface, hb_lv_surface) shares. See docs/adr/0102 for why this
 * host build reimplements the API this app runs against rather than
 * emulating the SoC/OS underneath the real SDK.
 */
#ifndef HB_SURFACE_INPUT_H
#define HB_SURFACE_INPUT_H

#include <stdint.h>

/* Current pointer state. x/y are screen pixels; `down` is 1 while pressed and 0
 * on release. On release x/y hold the LAST pressed position (so a tap handler
 * knows where the finger lifted). */
typedef struct { int16_t x, y; int down; } hb_spoint_t;

void hb_surface_touch_read(hb_spoint_t *out);

#endif /* HB_SURFACE_INPUT_H */
