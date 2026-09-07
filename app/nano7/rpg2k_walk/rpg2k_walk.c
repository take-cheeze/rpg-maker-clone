/*
 * rpg2k_walk -- walk a real RPG Maker 2000/2003 map on iPod nano 7th
 * generation homebrew (NanoApps SDK, RAW_SURFACE).
 *
 * This is deliberately NOT the mruby/RGSS engine the rest of this repo runs
 * everywhere else (PSP, Wio Terminal, Android, browser): NanoApps caps a
 * compiled app image at roughly 500 KB, and this repo's mruby + RGSS/RPG2k
 * gem stack is tens of MB even stripped -- see docs/adr/0061. Instead, all
 * LCF parsing and chipset/autotile compositing happens once on the host via
 * scripts/export_nano7_map.rb, which writes two flat files this app reads
 * with hb_fs_read and hands to the shared walk core. No LCF, no BER, no
 * autotile geometry on-device -- just array lookups and pixel blits.
 *
 * This file is only the NanoApps half: the buffers, the touch joystick, the
 * frame timing and the blitting. Everything portable -- the file format, the
 * movement rule, the camera, the per-cell compositing -- lives in
 * app/shared/rpg2k_walk/rpg2k_walk_core.c, which the Wio Terminal walk
 * firmware (app/wio/src/walk_main.cxx) runs too. See docs/adr/0091.
 *
 * Scope (see docs/adr/0061 for the full rationale): one static map, no
 * events/interpreter/battle/menus, tiles frozen at their first animation
 * frame. This walks a real map; it does not play the game.
 *
 * Input: hold anywhere on screen. The direction is whichever of up/down/
 * left/right is furthest from screen center (a whole-screen virtual
 * joystick, the same "zone" input convention apps/tetris and apps/paint
 * use), and the player steps one tile every STEP_INTERVAL_MS while held,
 * blocked by the exported passability mask.
 */
#include "hb_raw_surface.h"
#include "hb_sdk.h"
#include "rpg2k_walk_core.h"

/* This device's own caps: the sizes of the two buffers below, and so the
 * largest export it can load (the core refuses anything that does not fit
 * rather than reading past them). Mirrored in scripts/export_nano7_map.rb's
 * nano7 target, which refuses an oversized map at export time instead of
 * leaving it to fail on-device.
 *
 * Sized to keep total .bss comfortably under the ~512 KB gap between BSS_VA
 * and LINK_VA in sdk/hb_app.mk (0x09200000..0x09280000) -- that gap is not
 * documented as a hard per-app .bss ceiling, but nothing in the SDK says it
 * is safe to exceed either, so this stays well under it rather than finding
 * out on real hardware. Raise with caution.
 *
 * At these caps the static buffers below are the whole of .bss: 82,450 B of
 * map.bin (its palette included) + 65,536 B of atlas + 1,536 B of composited
 * cell = ~146 KB. The atlas has halved twice: 32-bit pixels became 16-bit
 * with the transparency fix, then one palette index per pixel in format v3
 * (docs/adr/0092), which is why these caps now leave room to spare rather
 * than needing to grow. */
#define MAP_MAX_W 128
#define MAP_MAX_H 128
#define MAX_TILES 256

#define MAP_BIN_MAX_BYTES                                   \
    (RW_MAP_HEADER_BYTES + RW_MAX_PALETTE * 2 +             \
     MAP_MAX_W * MAP_MAX_H * RW_MAP_BYTES_PER_CELL)

#define MAP_DATA_DIR "/Apps/Data/RPG2kWalk"

#define STEP_INTERVAL_MS 160u

static uint8_t s_map_raw[MAP_BIN_MAX_BYTES];
/* One palette index per pixel; the colours live in map.bin's palette. */
static uint8_t s_tiles[MAX_TILES * RW_TILE_PIXELS];
/* One composited cell in the surface's own pixel format: hb_raw_blit takes a
 * finished tile, so each cell is merged (see rw_compose_cell) and converted
 * once, then blitted once. */
static uint32_t s_cell[RW_TILE_PIXELS];
/* The same cell before conversion. Static rather than a local: .bss is the
 * budget this app has to spare, the stack on a homebrew app is whatever the
 * loader left it. */
static uint16_t s_cell_1555[RW_TILE_PIXELS];

static rw_map s_map;
static rw_status s_status;

static uint32_t s_last_step_ms;

/* ARGB1555 -> the surface's 8-bit-per-channel pixel. The low bits are
 * replicated into the gap (r << 3 | r >> 2) so a full-scale 31 maps to 255
 * rather than 248 -- otherwise white greys out. */
static uint32_t rgb1555_to_native(uint16_t c)
{
    unsigned r = (c >> 10) & 0x1fu, g = (c >> 5) & 0x1fu, b = c & 0x1fu;
    return HB_RGB((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2));
}

static rw_status load_map(void)
{
    uint32_t map_len = hb_fs_read(MAP_DATA_DIR "/map.bin", s_map_raw, sizeof(s_map_raw));
    uint32_t tiles_len = hb_fs_read(MAP_DATA_DIR "/tiles.bin", s_tiles, sizeof(s_tiles));

    return rw_open(&s_map, s_map_raw, map_len, s_tiles, tiles_len);
}

/* Whole-screen virtual joystick: the axis furthest from center wins, same
 * "zone" input convention apps/tetris and apps/paint use. A small deadzone
 * around center avoids jitter from an imprecise tap. */
static void touch_direction(const hb_spoint_t *t, int *dx, int *dy)
{
    *dx = 0;
    *dy = 0;
    if (!t->down) return;
    int cx = hb_raw_w() / 2, cy = hb_raw_h() / 2;
    int ddx = t->x - cx, ddy = t->y - cy;
    int adx = ddx < 0 ? -ddx : ddx;
    int ady = ddy < 0 ? -ddy : ddy;
    const int DEADZONE = 12;
    if (adx < DEADZONE && ady < DEADZONE) return;
    if (adx > ady) *dx = ddx > 0 ? 1 : -1;
    else *dy = ddy > 0 ? 1 : -1;
}

static void draw_map(void)
{
    int view_w = hb_raw_w() / RW_TS;
    int view_h = hb_raw_h() / RW_TS;
    int cam_x, cam_y;
    rw_camera(&s_map, view_w, view_h, &cam_x, &cam_y);

    hb_raw_fill(rgb1555_to_native(s_map.backdrop));

    for (int ty = 0; ty < view_h; ty++) {
        int my = cam_y + ty;
        if (my >= s_map.height) break;
        for (int tx = 0; tx < view_w; tx++) {
            int mx = cam_x + tx;
            if (mx >= s_map.width) break;

            rw_compose_cell(&s_map, mx, my, s_cell_1555);
            for (int i = 0; i < RW_TILE_PIXELS; i++)
                s_cell[i] = rgb1555_to_native(s_cell_1555[i]);

            hb_raw_blit(tx * RW_TS, ty * RW_TS, RW_TS, RW_TS, s_cell);
        }
    }

    int ppx = (s_map.player_x - cam_x) * RW_TS, ppy = (s_map.player_y - cam_y) * RW_TS;
    hb_raw_disc(ppx + RW_TS / 2, ppy + RW_TS / 2, RW_TS / 2 - 1, HB_RGB(0xff, 0x40, 0x40));
}

void hb_raw_init(int w, int h)
{
    (void)w;
    (void)h;
    s_status = load_map();
    s_last_step_ms = hb_time_uptime_ms();
    if (s_status == RW_OK) {
        draw_map();
    } else {
        hb_raw_fill(HB_BLACK);
        hb_draw_str(8, 8, "no map to walk:", 2, HB_WHITE, HB_BLACK);
        hb_draw_str(8, 32, rw_status_str(s_status), 2, HB_WHITE, HB_BLACK);
        hb_draw_str(8, 56, "run export_nano7_map.rb,", 2, HB_WHITE, HB_BLACK);
        hb_draw_str(8, 80, "copy to " MAP_DATA_DIR, 2, HB_WHITE, HB_BLACK);
    }
}

void hb_raw_frame(const hb_spoint_t *touch)
{
    if (s_status != RW_OK) return;

    int dx, dy;
    touch_direction(touch, &dx, &dy);

    if (dx != 0 || dy != 0) {
        uint32_t now = hb_time_uptime_ms();
        if (now - s_last_step_ms >= STEP_INTERVAL_MS) {
            rw_try_move(&s_map, dx, dy);
            s_last_step_ms = now;
            draw_map();
        }
    } else {
        /* Released: next hold steps immediately rather than waiting out
         * whatever fraction of the interval elapsed before release. */
        s_last_step_ms = hb_time_uptime_ms() - STEP_INTERVAL_MS;
    }
}
