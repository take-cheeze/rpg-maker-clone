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
 * interpreter/battle/menus. Water and the block-C animated tiles do
 * animate, on RPG2000's own two clocks (docs/adr/0094) -- the export asks
 * mruby-rpg2k what those are, so this file only advances a counter and
 * redraws the cells the core says moved. The player is the project's own
 * initial party leader, drawn as their real CharSet sprite when one was
 * exported (docs/adr/0096) rather than a plain marker, walking RPG2000's own
 * cycle and turning to face a bump the same way the genuine renderer does.
 * A map event with a CharSet graphic on its own initially-active page draws
 * too, as a single static sprite (docs/adr/0102) -- its own walk cycle,
 * move route and runtime graphic changes all need the interpreter and stay
 * out of scope, same as everything else events could otherwise do.
 * This walks a real map; it does not play the game.
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

/* This device's own caps: the sizes of the buffers below, and so the
 * largest export it can load (the core refuses anything that does not fit
 * rather than reading past them). Mirrored in scripts/export_nano7_map.rb's
 * nano7 target, which refuses an oversized map at export time instead of
 * leaving it to fail on-device.
 *
 * Sized to keep total .bss comfortably under the ~512 KB gap between BSS_VA
 * and LINK_VA in sdk/hb_app.mk (0x09200000..0x09280000). Correction, found
 * building docs/adr/0103's QEMU harness: that gap is specifically for
 * LV_SURFACE apps sharing address space with the live compositor
 * (hb_app.mk's own comment: parking .bss there is so such an app doesn't
 * stomp the compositor's heap) -- this app builds RAW_SURFACE, i.e. RELOC,
 * whose .bss the resident instead gives "an operator-new arena" (same
 * file), not that fixed gap. So this was never actually the enforced
 * per-app ceiling it was assumed to be; the real, ADR-61-verified NanoApps
 * limit for a RELOC app is the ~500 KB packed .hbapp blob (code + reloc
 * table), which this file's own .text/.rodata sits nowhere near. The ~512
 * KB figure below is kept anyway as this app's own conservative,
 * self-imposed budget -- docs/adr/0103's app_bss linker region now enforces
 * it at link time for the QEMU build, which is more than a comment ever
 * did -- not because it turned out to be a real hardware ceiling after all.
 * Raise with caution regardless: still unverified against real allocator
 * behaviour either way.
 *
 * At these caps the static buffers below are the whole of .bss: 46,872 B of
 * map.bin (its palette, entry and event tables included) + 65,280 B of atlas
 * + 9,216 B of hero frames + 49,152 B of event frames + 1,536 B of
 * composited cell + 1,536 B of the hero's own composited frame + 1,536 B of
 * an event's own composited frame = ~171 KB, still well under the ~512 KB
 * gap. Both halves have shrunk in turn: the atlas twice (32-bit pixels to
 * 16-bit with the transparency fix, then one palette index per pixel,
 * docs/adr/0092) and the cell arrays once (2.5 bytes per cell,
 * docs/adr/0093), which is why the hero frames (docs/adr/0096) and the
 * event-sprite atlas (docs/adr/0102) -- fixed costs, not scaled by map
 * size -- still leave these caps room to spare rather than needing to
 * grow. */
#define MAP_MAX_W 128
#define MAP_MAX_H 128
#define MAX_TILES RW_MAX_TILES
/* Mirrors export_nano7_map.rb's own `nano7` target max_event_frames/
 * max_events -- see that file's own comment for the RAM budget and
 * real-data numbers behind these (real worst case in the Nepheshel test
 * bed: 256 events, 12 distinct frames, on its most event-heavy map). */
#define MAX_EVENT_FRAMES 64
#define MAX_EVENTS 1024

#define MAP_BIN_MAX_BYTES                                              \
    (RW_MAP_HEADER_BYTES + RW_MAX_PALETTE * 2 +                        \
     RW_MAX_TILES * RW_ENTRY_BYTES + (uint32_t)MAX_EVENTS * RW_EVENT_BYTES + \
     RW_MAP_CELL_BYTES(MAP_MAX_W * MAP_MAX_H))

#define MAP_DATA_DIR "/Apps/Data/RPG2kWalk"

#define STEP_INTERVAL_MS 160u

static uint8_t s_map_raw[MAP_BIN_MAX_BYTES];
/* One palette index per pixel; the colours live in map.bin's palette. The
 * hero's own frames (RW_HERO_FRAMES_BYTES), when the export carries one, sit
 * right after the ordinary atlas, then up to MAX_EVENT_FRAMES more -- see
 * rw_open. Both reserved unconditionally: a fixed size is cheaper than a
 * second/third buffer size to get right. */
static uint8_t s_tiles[MAX_TILES * RW_TILE_PIXELS + RW_HERO_FRAMES_BYTES +
                       MAX_EVENT_FRAMES * RW_EVENT_FRAME_PIXELS];
/* One composited cell in the surface's own pixel format: hb_raw_blit takes a
 * finished tile, so each cell is merged (see rw_compose_cell) and converted
 * once, then blitted once. */
static uint32_t s_cell[RW_TILE_PIXELS];
/* The same cell before conversion. Static rather than a local: .bss is the
 * budget this app has to spare, the stack on a homebrew app is whatever the
 * loader left it. */
static uint16_t s_cell_1555[RW_TILE_PIXELS];
/* The hero's own composited frame, same convention as s_cell_1555 except a
 * transparent pixel stays 0 rather than resolving to the backdrop -- see
 * rw_compose_hero -- so draw_hero skips it instead of blitting over it. */
static uint16_t s_hero_1555[RW_HERO_FRAME_PIXELS];
/* One event's own composited frame, same convention as s_hero_1555. */
static uint16_t s_event_1555[RW_EVENT_FRAME_PIXELS];

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

static void blit_cell(int tx, int ty, int mx, int my)
{
    rw_compose_cell(&s_map, mx, my, s_cell_1555);
    for (int i = 0; i < RW_TILE_PIXELS; i++)
        s_cell[i] = rgb1555_to_native(s_cell_1555[i]);

    hb_raw_blit(tx * RW_TS, ty * RW_TS, RW_TS, RW_TS, s_cell);
}

/* The hero sprite, drawn over whatever the cell loop above already put down:
 * wider and taller than a tile (rw_hero_screen_pos centres and bottom-
 * anchors it the same way the genuine renderer does) and, unlike a cell, not
 * every pixel is opaque -- a transparent one is skipped rather than blitted,
 * so hb_raw_blit's unconditional rect copy cannot draw this, and it goes
 * straight to the framebuffer pixel by pixel instead. No hero was exported
 * for a project whose initial party carries no CharSet (rw_compose_hero
 * fills s_hero_1555 with all zeroes then), so this simply draws nothing. */
static void draw_hero(int cam_x, int cam_y, int moving)
{
    int x, y, px, py;
    uint32_t *fb = hb_raw_fb();
    int fb_w = hb_raw_w(), fb_h = hb_raw_h();

    rw_compose_hero(&s_map, moving, s_hero_1555);
    rw_hero_screen_pos(&s_map, cam_x, cam_y, &px, &py);

    for (y = 0; y < RW_HERO_FRAME_H; y++) {
        int sy = py + y;
        if (sy < 0 || sy >= fb_h) continue;
        for (x = 0; x < RW_HERO_FRAME_W; x++) {
            uint16_t c = s_hero_1555[y * RW_HERO_FRAME_W + x];
            int sx = px + x;
            if (c == 0 || sx < 0 || sx >= fb_w) continue;
            fb[sy * fb_w + sx] = rgb1555_to_native(c);
        }
    }
}

/* One event sprite, the same shape as draw_hero but with no live facing or
 * walk cycle to pick between -- rw_compose_event already names the one
 * frame the export chose for this event's initially-active page. Always
 * redrawn along with every other event whenever draw_map runs at all,
 * moving_only included, for the same reason draw_hero is: an animation
 * tick's cell repaint can land on a tile a static event sprite is sitting
 * on, and only redrawing it again on top -- rather than skipping it because
 * nothing about the *event* changed -- keeps it from being erased. */
static void draw_event(int index, int cam_x, int cam_y)
{
    int x, y, px, py;
    uint32_t *fb = hb_raw_fb();
    int fb_w = hb_raw_w(), fb_h = hb_raw_h();

    rw_compose_event(&s_map, index, s_event_1555);
    rw_event_screen_pos(&s_map, index, cam_x, cam_y, &px, &py);

    for (y = 0; y < RW_EVENT_FRAME_H; y++) {
        int sy = py + y;
        if (sy < 0 || sy >= fb_h) continue;
        for (x = 0; x < RW_EVENT_FRAME_W; x++) {
            uint16_t c = s_event_1555[y * RW_EVENT_FRAME_W + x];
            int sx = px + x;
            if (c == 0 || sx < 0 || sx >= fb_w) continue;
            fb[sy * fb_w + sx] = rgb1555_to_native(c);
        }
    }
}

/* `moving_only` redraws just the cells whose tiles the clocks moved, for an
 * animation tick: on a typical map that is the water and nothing else, so a
 * tick costs a fraction of a full redraw. A step or a first paint passes 0
 * and draws everything. The hero and every event always redraw on top
 * regardless -- an animation tick can repaint a cell either overlaps, and
 * the hero's own pose can have changed on a step this same call is already
 * handling. */
static void draw_map(int moving_only, int moving)
{
    int view_w = hb_raw_w() / RW_TS;
    int view_h = hb_raw_h() / RW_TS;
    int cam_x, cam_y;
    rw_camera(&s_map, view_w, view_h, &cam_x, &cam_y);

    if (!moving_only) hb_raw_fill(rgb1555_to_native(s_map.backdrop));

    for (int ty = 0; ty < view_h; ty++) {
        int my = cam_y + ty;
        if (my >= s_map.height) break;
        for (int tx = 0; tx < view_w; tx++) {
            int mx = cam_x + tx;
            if (mx >= s_map.width) break;
            if (moving_only && !rw_cell_animated(&s_map, mx, my)) continue;

            blit_cell(tx, ty, mx, my);
        }
    }

    /* Below/same-behind first (under the hero), then the hero, then
     * same-in-front/above (over the hero) -- rw_event_before_hero's own doc
     * comment names the exact rule, matching the genuine renderer's
     * event_target_buffer split. Events export sorted by (y, x)
     * (export_nano7_map.rb), so this loop's own draw order within each half
     * already matches RPG_RT's same-tier y-sort with no on-device work. */
    for (int i = 0; i < s_map.event_count; i++)
        if (rw_event_before_hero(&s_map, i)) draw_event(i, cam_x, cam_y);
    draw_hero(cam_x, cam_y, moving);
    for (int i = 0; i < s_map.event_count; i++)
        if (!rw_event_before_hero(&s_map, i)) draw_event(i, cam_x, cam_y);
}

/* RPG2000 counts animation in 60ths of a second, which is what the export's
 * clock periods are in; 3/50 is that ratio exactly. */
static uint32_t rpg_frame(void)
{
    return (hb_time_uptime_ms() * 3u) / 50u;
}

void hb_raw_init(int w, int h)
{
    (void)w;
    (void)h;
    s_status = load_map();
    s_last_step_ms = hb_time_uptime_ms();
    if (s_status == RW_OK) {
        rw_set_frame(&s_map, rpg_frame());
        draw_map(0, 0);
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
    int moving = dx != 0 || dy != 0;

    if (moving) {
        uint32_t now = hb_time_uptime_ms();
        if (now - s_last_step_ms >= STEP_INTERVAL_MS) {
            rw_try_move(&s_map, dx, dy);
            s_last_step_ms = now;
            rw_set_frame(&s_map, rpg_frame());
            draw_map(0, 1);
            return;
        }
    } else {
        /* Released: next hold steps immediately rather than waiting out
         * whatever fraction of the interval elapsed before release. */
        s_last_step_ms = hb_time_uptime_ms() - STEP_INTERVAL_MS;
    }

    /* A still map never reaches the redraw: rw_set_frame reports a step only
     * when a clock this map actually uses has moved. Still redraws the hero
     * on its own, held-direction pose -- a bump against a wall keeps the
     * walk cycle alive rather than freezing mid-step. */
    if (s_map.animated && rw_set_frame(&s_map, rpg_frame()))
        draw_map(1, moving);
}
