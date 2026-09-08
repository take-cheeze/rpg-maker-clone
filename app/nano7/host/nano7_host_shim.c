/*
 * nano7_host_shim -- the host-platform half of a hb_raw_surface/hb_sdk
 * implementation for app/nano7/rpg2k_walk/rpg2k_walk.c: hb_fs_read (over
 * stdio), hb_time_uptime_ms, and a main() driving it via SDL2 for a window
 * or headlessly. The framebuffer array, the hb_raw_ pixel primitives and
 * hb_draw_str are shared with app/nano7/qemu's bare-metal build -- see
 * app/nano7/shim_common/hb_fb_ops.c.
 *
 * See docs/adr/0102-ipod-nano-7-host-emulator.md for why this repo builds a
 * host implementation of the app's own API instead of emulating the real
 * device's Cortex-A8 SoC and proprietary OS underneath that API (unlike the
 * Wio Terminal's bare-metal Renode platform, docs/adr/0094, where modelling
 * the SoC *is* modelling the firmware's whole execution environment), and
 * docs/adr/0103-ipod-nano-7-qemu-cortex-a8-emulation.md for app/nano7/qemu,
 * which -- unlike this file -- *does* run the real ARM Cortex-A8 instruction
 * stream, for a genuine (if approximate) CPU cost signal this file's native
 * host execution cannot give at all.
 *
 * This file links app/nano7/rpg2k_walk/rpg2k_walk.c and
 * app/shared/rpg2k_walk/rpg2k_walk_core.c completely unmodified -- the only
 * new code here is what the real NanoApps SDK/resident would otherwise
 * supply underneath them.
 *
 * Usage:
 *   nano7_walk_host DATA_ROOT                       interactive SDL window,
 *                                                    mouse-as-touch
 *   nano7_walk_host DATA_ROOT --frames N             headless: run N
 *                              [--screenshot PATH]   simulated ticks (20 ms
 *                                                     apart) then optionally
 *                                                     save the final frame
 *
 * DATA_ROOT holds an exported map the same relative layout the real
 * device's own volume does: DATA_ROOT/Apps/Data/RPG2kWalk/{map,tiles}.bin
 * (rpg2k_walk.c's own MAP_DATA_DIR constant), so scripts/export_nano7_map.rb
 * can write straight into a staged tree that would also be a valid on-device
 * data directory.
 */
#include <SDL2/SDL.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hb_raw_surface.h"
#include "hb_sdk.h"

/* hb_raw_fb() and the pixel primitives are app/nano7/shim_common/hb_fb_ops.c
 * (shared with app/nano7/qemu); this file needs read access to the same
 * array for the interactive texture update and the BMP screenshot. */
extern uint32_t *hb_raw_fb(void);

/* ---- hb_sdk.h's platform-specific half ---- */

/* rpg2k_walk.c reads "/Apps/Data/RPG2kWalk/map.bin" and "/.../tiles.bin"
 * (MAP_DATA_DIR); joined onto a host root given on the command line rather
 * than a real device's volume root. */
static char s_data_root[1024] = ".";

uint32_t hb_fs_read(const char *path, void *buf, uint32_t max_size) {
  char full[2048];
  snprintf(full, sizeof full, "%s%s", s_data_root, path);
  FILE *f = fopen(full, "rb");
  if (!f) return 0;
  size_t n = fread(buf, 1, max_size, f);
  fclose(f);
  return (uint32_t)n;
}

/* Real wall-clock time in interactive mode; a harness-advanced counter in
 * headless mode, so a batch run's STEP_INTERVAL_MS-gated movement in
 * rpg2k_walk.c fires on an exact, reproducible schedule instead of racing
 * however fast the host happens to loop. */
static int s_headless;
static uint32_t s_sim_ms;

uint32_t hb_time_uptime_ms(void) {
  return s_headless ? s_sim_ms : (uint32_t)SDL_GetTicks();
}

/* ---- the harness ---- */

/* A minimal, self-written 24bpp BMP writer for the headless screenshot,
 * rather than SDL_SaveBMP: this repo's own scripts/nano7_host_smoke_check.rb
 * (a plain-Ruby reader, no ImageMagick, matching scripts/mz_frame_check.rb's
 * own PNG reader) needs to know exactly what's on disk, and SDL_SaveBMP's
 * output bit depth depends on the surface format passed to it in ways this
 * file would rather not have to keep in sync with a second, independent
 * implementation. Writing (and reading back) one fixed, fully-specified
 * format is simpler than verifying two general-purpose ones agree. Standard
 * bottom-up, row-padded-to-4-bytes, uncompressed BGR888 -- the plainest BMP
 * variant there is. */
static int write_bmp24(const char *path, int w, int h, const uint32_t *px) {
  int row_bytes = w * 3;
  int pad = (4 - (row_bytes % 4)) % 4;
  int row_size = row_bytes + pad;
  uint32_t data_size = (uint32_t)row_size * (uint32_t)h;
  uint32_t file_size = 14u + 40u + data_size;

  FILE *f = fopen(path, "wb");
  if (!f) return -1;

  uint8_t file_hdr[14] = {
      'B', 'M',
      (uint8_t)file_size, (uint8_t)(file_size >> 8), (uint8_t)(file_size >> 16),
      (uint8_t)(file_size >> 24),
      0, 0, 0, 0,
      54, 0, 0, 0,
  };
  fwrite(file_hdr, 1, sizeof file_hdr, f);

  uint8_t info_hdr[40] = {0};
  info_hdr[0] = 40;
  int32_t width = w, height = h;
  memcpy(&info_hdr[4], &width, 4);
  memcpy(&info_hdr[8], &height, 4); /* positive: bottom-up rows */
  info_hdr[12] = 1;                 /* planes */
  info_hdr[14] = 24;                /* bitcount */
  memcpy(&info_hdr[20], &data_size, 4);
  fwrite(info_hdr, 1, sizeof info_hdr, f);

  uint8_t *row = calloc(1, (size_t)row_size);
  int ok = row != NULL;
  for (int y = h - 1; ok && y >= 0; y--) {
    for (int x = 0; x < w; x++) {
      uint32_t c = px[y * w + x];
      row[x * 3 + 0] = (uint8_t)(c & 0xFFu);         /* B */
      row[x * 3 + 1] = (uint8_t)((c >> 8) & 0xFFu);  /* G */
      row[x * 3 + 2] = (uint8_t)((c >> 16) & 0xFFu); /* R */
    }
    if (fwrite(row, 1, (size_t)row_size, f) != (size_t)row_size) ok = 0;
  }
  free(row);
  fclose(f);
  return ok ? 0 : -1;
}

static void usage(const char *argv0) {
  fprintf(stderr,
          "usage: %s DATA_ROOT [--frames N] [--screenshot PATH]\n"
          "  DATA_ROOT     directory holding Apps/Data/RPG2kWalk/{map,tiles}.bin\n"
          "  --frames N    headless: run N simulated 20ms ticks, then exit\n"
          "                (omit for an interactive window, mouse-as-touch)\n"
          "  --screenshot PATH  save the final frame as a BMP (headless only)\n",
          argv0);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    usage(argv[0]);
    return 1;
  }
  snprintf(s_data_root, sizeof s_data_root, "%s", argv[1]);

  int frames = 0;
  const char *screenshot = NULL;
  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
      frames = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--screenshot") == 0 && i + 1 < argc) {
      screenshot = argv[++i];
    } else {
      usage(argv[0]);
      return 1;
    }
  }

  hb_raw_init(HB_SCREEN_W, HB_SCREEN_H);

  if (frames > 0) {
    /* Headless: hb_raw_fb() is a plain in-process array and write_bmp24 is
     * this file's own code, so nothing below calls into SDL at all -- no
     * SDL_Init, no window, no Xvfb needed in CI. A synthetic held "move
     * down" touch starts a few frames in (after the first static paint) so
     * the run exercises rw_try_move, the animation clocks and the hero
     * sprite, not only hb_raw_init's initial frame. */
    s_headless = 1;
    s_sim_ms = 0;
    hb_spoint_t touch = {0, 0, 0};
    for (int i = 0; i < frames; i++) {
      if (i >= 3) {
        touch.down = 1;
        touch.x = HB_SCREEN_W / 2;
        touch.y = (int16_t)(HB_SCREEN_H / 2 + 80);
      }
      hb_raw_frame(&touch);
      s_sim_ms += 20;
    }
    if (screenshot && write_bmp24(screenshot, HB_SCREEN_W, HB_SCREEN_H, hb_raw_fb()) != 0) {
      fprintf(stderr, "screenshot failed: could not write %s\n", screenshot);
      return 1;
    }
    return 0;
  }

  /* Interactive: a real window, so this half does need SDL's video subsystem. */
  if (SDL_Init(SDL_INIT_VIDEO) != 0) {
    fprintf(stderr, "SDL_Init(VIDEO) failed: %s\n", SDL_GetError());
    return 1;
  }
  SDL_Window *win = SDL_CreateWindow("iPod nano 7G walk (host)", SDL_WINDOWPOS_CENTERED,
                                      SDL_WINDOWPOS_CENTERED, HB_SCREEN_W, HB_SCREEN_H, 0);
  SDL_Renderer *ren = SDL_CreateRenderer(win, -1, 0);
  SDL_Texture *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGB888,
                                        SDL_TEXTUREACCESS_STREAMING, HB_SCREEN_W, HB_SCREEN_H);
  if (!win || !ren || !tex) {
    fprintf(stderr, "SDL window setup failed: %s\n", SDL_GetError());
    return 1;
  }

  hb_spoint_t touch = {0, 0, 0};
  int running = 1;
  while (running) {
    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
      switch (ev.type) {
        case SDL_QUIT:
          running = 0;
          break;
        case SDL_MOUSEBUTTONDOWN:
          touch.down = 1;
          touch.x = (int16_t)ev.button.x;
          touch.y = (int16_t)ev.button.y;
          break;
        case SDL_MOUSEMOTION:
          if (touch.down) {
            touch.x = (int16_t)ev.motion.x;
            touch.y = (int16_t)ev.motion.y;
          }
          break;
        case SDL_MOUSEBUTTONUP:
          touch.down = 0;
          break;
      }
    }

    hb_raw_frame(&touch);

    SDL_UpdateTexture(tex, NULL, hb_raw_fb(), HB_SCREEN_W * 4);
    SDL_RenderClear(ren);
    SDL_RenderCopy(ren, tex, NULL, NULL);
    SDL_RenderPresent(ren);
    SDL_Delay(16); /* ~60 fps, matching the real device's heartbeat */
  }

  SDL_DestroyTexture(tex);
  SDL_DestroyRenderer(ren);
  SDL_DestroyWindow(win);
  SDL_Quit();
  return 0;
}
