/*
 * hb_fb_ops -- the platform-INDEPENDENT half of every hb_raw_surface/hb_sdk
 * implementation this repo builds for the iPod nano 7G app
 * (app/nano7/rpg2k_walk/rpg2k_walk.c): the framebuffer array itself, the six
 * hb_raw_* pixel primitives, and the hb_draw_str placeholder. None of this
 * file touches a file, a clock, or a register -- that's each platform's own
 * job (app/nano7/host/nano7_host_shim.c's stdio + SDL_GetTicks,
 * app/nano7/qemu/nano7_qemu_shim.c's PL011/PL110/PMU MMIO). Sharing this file
 * is what keeps both "emulators" honouring the exact same clipping and
 * compositing rules -- a divergence here would quietly invalidate either
 * one's claim to reproduce the real device's rendering. See
 * docs/adr/0102-ipod-nano-7-host-emulator.md and
 * docs/adr/0103-ipod-nano-7-qemu-cortex-a8-emulation.md.
 *
 * Freestanding: no libc, matching app/shared/rpg2k_walk_core.c's own
 * constraint, since app/nano7/qemu links this for a bare-metal target with
 * no libc at all.
 */
#include "hb_raw_surface.h"
#include "hb_sdk.h"

static uint32_t s_fb[HB_SCREEN_W * HB_SCREEN_H];

uint32_t *hb_raw_fb(void) { return s_fb; }
int hb_raw_w(void) { return HB_SCREEN_W; }
int hb_raw_h(void) { return HB_SCREEN_H; }

static inline void put_px(int x, int y, uint32_t rgb) {
  if ((unsigned)x < (unsigned)HB_SCREEN_W && (unsigned)y < (unsigned)HB_SCREEN_H)
    s_fb[y * HB_SCREEN_W + x] = rgb;
}

void hb_raw_fill(uint32_t rgb) {
  for (int i = 0; i < HB_SCREEN_W * HB_SCREEN_H; i++) s_fb[i] = rgb;
}

void hb_raw_fill_rect(int x, int y, int w, int h, uint32_t rgb) {
  for (int yy = y; yy < y + h; yy++)
    for (int xx = x; xx < x + w; xx++) put_px(xx, yy, rgb);
}

void hb_raw_rect_outline(int x, int y, int w, int h, int t, uint32_t rgb) {
  hb_raw_fill_rect(x, y, w, t, rgb);
  hb_raw_fill_rect(x, y + h - t, w, t, rgb);
  hb_raw_fill_rect(x, y, t, h, rgb);
  hb_raw_fill_rect(x + w - t, y, t, h, rgb);
}

void hb_raw_disc(int cx, int cy, int r, uint32_t rgb) {
  for (int yy = -r; yy <= r; yy++)
    for (int xx = -r; xx <= r; xx++)
      if (xx * xx + yy * yy <= r * r) put_px(cx + xx, cy + yy, rgb);
}

void hb_raw_blit(int x, int y, int w, int h, const uint32_t *src) {
  for (int yy = 0; yy < h; yy++)
    for (int xx = 0; xx < w; xx++) put_px(x + xx, y + yy, src[yy * w + xx]);
}

/* NOT a faithful replica of the real device's glyph bitmap font
 * (NanoApps' sdk/generated/hb_glyphs.c) -- a blocky per-character rectangle
 * instead. rpg2k_walk.c only calls this for its "no map to walk" error
 * screen, never the map-rendering path either harness exists to check. */
void hb_draw_str(int16_t x, int16_t y, const char *s, uint8_t scale,
                  hb_color_t fg, hb_color_t bg) {
  int cell = 8 * scale;
  for (; *s; s++, x = (int16_t)(x + cell)) {
    hb_raw_fill_rect(x, y, cell, cell, bg);
    if (*s != ' ') hb_raw_fill_rect(x + 1, y + 1, cell - 2, cell - 2, fg);
  }
}
