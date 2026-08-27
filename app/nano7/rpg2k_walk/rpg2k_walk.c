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
 * with hb_fs_read and indexes directly. No LCF, no BER, no autotile geometry
 * on-device -- just array lookups and pixel blits.
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

#define TS 16 /* chipset tile size, matches scripts/export_nano7_map.rb */
#define TILE_PIXELS (TS * TS)

/* On-device caps, mirrored in scripts/export_nano7_map.rb's MAP_MAX_W/H and
 * MAX_TILES. Sized to keep total .bss comfortably under the ~512 KB gap
 * between BSS_VA and LINK_VA in sdk/hb_app.mk (0x09200000..0x09280000) --
 * that gap is not documented as a hard per-app .bss ceiling, but nothing in
 * the SDK says it is safe to exceed either, so this stays well under it
 * rather than finding out on real hardware. Raise with caution. */
#define MAP_MAX_W 128
#define MAP_MAX_H 128
#define MAX_TILES 256

#define MAP_CELLS (MAP_MAX_W * MAP_MAX_H)
/* map.bin layout: 18-byte header + cells*(u16 lower + u16 upper + u8 passable). */
#define MAP_BIN_MAX_BYTES (18 + MAP_CELLS * 5)

#define UPPER_NONE 0xFFFFu

/* Matches DIR_BITS in scripts/export_nano7_map.rb (RPG2000's own numpad
 * direction convention, Game::ChipSet::DIR_BIT in mruby-rpg2k/mrblib/game.rb). */
#define DIR_DOWN_BIT 0x01
#define DIR_LEFT_BIT 0x02
#define DIR_RIGHT_BIT 0x04
#define DIR_UP_BIT 0x08

#define MAP_DATA_DIR "/Apps/Data/RPG2kWalk"

#define STEP_INTERVAL_MS 160u

static uint8_t s_map_raw[MAP_BIN_MAX_BYTES];
static uint32_t s_tiles[MAX_TILES * TILE_PIXELS];

static int s_map_w, s_map_h, s_tile_count;
static const uint8_t *s_lower_base, *s_upper_base, *s_pass_base;

static int s_player_x, s_player_y;
static uint32_t s_last_step_ms;
static int s_loaded;

static uint16_t rd_u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static uint16_t lower_at(int x, int y) { return rd_u16(s_lower_base + (long)(y * s_map_w + x) * 2); }
static uint16_t upper_at(int x, int y) { return rd_u16(s_upper_base + (long)(y * s_map_w + x) * 2); }
static uint8_t passable_at(int x, int y) { return s_pass_base[y * s_map_w + x]; }

static int in_bounds(int x, int y) { return x >= 0 && y >= 0 && x < s_map_w && y < s_map_h; }

static int load_map(void)
{
    uint32_t n = hb_fs_read(MAP_DATA_DIR "/map.bin", s_map_raw, sizeof(s_map_raw));
    if (n < 18) return 0;
    if (s_map_raw[0] != 'N' || s_map_raw[1] != '7' || s_map_raw[2] != 'W' || s_map_raw[3] != 'M') return 0;
    if (s_map_raw[4] != 1) return 0; /* version */

    int w = rd_u16(s_map_raw + 6);
    int h = rd_u16(s_map_raw + 8);
    int sx = rd_u16(s_map_raw + 10);
    int sy = rd_u16(s_map_raw + 12);
    int tile_count = rd_u16(s_map_raw + 14);
    if (w <= 0 || h <= 0 || w > MAP_MAX_W || h > MAP_MAX_H) return 0;
    if (tile_count > MAX_TILES) return 0;
    if (sx < 0 || sy < 0 || sx >= w || sy >= h) return 0;

    uint32_t cells = (uint32_t)w * (uint32_t)h;
    uint32_t expected = 18 + cells * 5;
    if (n < expected) return 0;

    s_map_w = w;
    s_map_h = h;
    s_tile_count = tile_count;
    s_player_x = sx;
    s_player_y = sy;
    s_lower_base = s_map_raw + 18;
    s_upper_base = s_lower_base + cells * 2;
    s_pass_base = s_upper_base + cells * 2;

    uint32_t tiles_bytes = (uint32_t)tile_count * TILE_PIXELS * 4;
    uint32_t got = hb_fs_read(MAP_DATA_DIR "/tiles.bin", s_tiles, sizeof(s_tiles));
    if (got < tiles_bytes) return 0;

    return 1;
}

/* Both halves of RPG2000's own movement check (mirrors
 * Scene::Map#char_passable? in mruby-rpg2k/mrblib/scene/map.rb): the current
 * cell must permit leaving in `dir`, AND the target cell must permit
 * entering from the opposite direction. No event/blocker checks -- this
 * slice has no events. */
static int can_step(int dir_bit, int opp_bit, int nx, int ny)
{
    if (!in_bounds(nx, ny)) return 0;
    if ((passable_at(s_player_x, s_player_y) & dir_bit) == 0) return 0;
    if ((passable_at(nx, ny) & opp_bit) == 0) return 0;
    return 1;
}

static void try_move(int dx, int dy)
{
    int dir_bit, opp_bit;
    if (dx < 0) { dir_bit = DIR_LEFT_BIT; opp_bit = DIR_RIGHT_BIT; }
    else if (dx > 0) { dir_bit = DIR_RIGHT_BIT; opp_bit = DIR_LEFT_BIT; }
    else if (dy < 0) { dir_bit = DIR_UP_BIT; opp_bit = DIR_DOWN_BIT; }
    else { dir_bit = DIR_DOWN_BIT; opp_bit = DIR_UP_BIT; }

    int nx = s_player_x + dx, ny = s_player_y + dy;
    if (can_step(dir_bit, opp_bit, nx, ny)) {
        s_player_x = nx;
        s_player_y = ny;
    }
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
    int view_w = hb_raw_w() / TS;
    int view_h = hb_raw_h() / TS;

    int cam_x = s_player_x - view_w / 2;
    int cam_y = s_player_y - view_h / 2;
    if (cam_x > s_map_w - view_w) cam_x = s_map_w - view_w;
    if (cam_y > s_map_h - view_h) cam_y = s_map_h - view_h;
    if (cam_x < 0) cam_x = 0;
    if (cam_y < 0) cam_y = 0;

    hb_raw_fill(HB_BLACK);

    for (int ty = 0; ty < view_h; ty++) {
        int my = cam_y + ty;
        if (my >= s_map_h) break;
        for (int tx = 0; tx < view_w; tx++) {
            int mx = cam_x + tx;
            if (mx >= s_map_w) break;
            int px = tx * TS, py = ty * TS;

            uint16_t lo = lower_at(mx, my);
            if (lo < (uint16_t)s_tile_count)
                hb_raw_blit(px, py, TS, TS, &s_tiles[(uint32_t)lo * TILE_PIXELS]);

            uint16_t up = upper_at(mx, my);
            if (up != UPPER_NONE && up < (uint16_t)s_tile_count)
                hb_raw_blit(px, py, TS, TS, &s_tiles[(uint32_t)up * TILE_PIXELS]);
        }
    }

    int ppx = (s_player_x - cam_x) * TS, ppy = (s_player_y - cam_y) * TS;
    hb_raw_disc(ppx + TS / 2, ppy + TS / 2, TS / 2 - 1, HB_RGB(0xff, 0x40, 0x40));
}

void hb_raw_init(int w, int h)
{
    (void)w;
    (void)h;
    s_loaded = load_map();
    s_last_step_ms = hb_time_uptime_ms();
    if (s_loaded) {
        draw_map();
    } else {
        hb_raw_fill(HB_BLACK);
        hb_draw_str(8, 8, "no map.bin/tiles.bin", 2, HB_WHITE, HB_BLACK);
        hb_draw_str(8, 32, "run export_nano7_map.rb,", 2, HB_WHITE, HB_BLACK);
        hb_draw_str(8, 56, "copy to " MAP_DATA_DIR, 2, HB_WHITE, HB_BLACK);
    }
}

void hb_raw_frame(const hb_spoint_t *touch)
{
    if (!s_loaded) return;

    int dx, dy;
    touch_direction(touch, &dx, &dy);

    if (dx != 0 || dy != 0) {
        uint32_t now = hb_time_uptime_ms();
        if (now - s_last_step_ms >= STEP_INTERVAL_MS) {
            try_move(dx, dy);
            s_last_step_ms = now;
            draw_map();
        }
    } else {
        /* Released: next hold steps immediately rather than waiting out
         * whatever fraction of the interval elapsed before release. */
        s_last_step_ms = hb_time_uptime_ms() - STEP_INTERVAL_MS;
    }
}
