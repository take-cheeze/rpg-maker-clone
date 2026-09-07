/*
 * Host unit test for the shared map-walk core (rpg2k_walk_core.c), run by
 * CTest as `walk_core`.
 *
 * The two devices this core runs on -- an iPod nano 7G under NanoApps and a
 * Wio Terminal under Arduino -- are outside CI: no emulator, no board, and
 * for the nano no toolchain either (ADR 61, ADR 7). The core is plain C with
 * no I/O, so the half of those firmwares that can actually be wrong in an
 * interesting way (format parsing, the palette, the movement rule, camera
 * clamping, layer compositing) is exactly the half a host compiler can run.
 * Fixtures here are synthetic, built byte by byte in the format the exporter
 * writes; scripts/export_nano7_map_check.rb covers the other side of that
 * contract against real game data.
 */
#include <stdio.h>
#include <string.h>

#include "rpg2k_walk_core.h"

static int g_failures;
static int g_checks;

static void check(int cond, const char* what) {
  g_checks++;
  if (!cond) {
    g_failures++;
    fprintf(stderr, "FAIL: %s\n", what);
  }
}

#define W 4
#define H 3
#define TILES 3

/* Palette: 0 is the transparent slot, then red and green. The backdrop is a
 * direct colour rather than an index, so blue is not in the palette. */
#define PAL_COUNT 3
#define IDX_RED 1
#define IDX_GREEN 2
#define RED (RW_OPAQUE | (31u << 10))
#define GREEN (RW_OPAQUE | (31u << 5))
#define BLUE (RW_OPAQUE | 31u)

#define PAL_BYTES (PAL_COUNT * 2)
#define MAP_BYTES (RW_MAP_HEADER_BYTES + PAL_BYTES + RW_MAP_CELL_BYTES(W * H))
#define CELLS_AT (RW_MAP_HEADER_BYTES + PAL_BYTES)
#define UPPER_AT (CELLS_AT + W * H)
#define PASS_AT (UPPER_AT + W * H)

static uint8_t g_map[MAP_BYTES];
static uint8_t g_tiles[TILES * RW_TILE_PIXELS];

static void set_passable(int x, int y, unsigned bits);

static void put_u16(uint8_t* p, unsigned v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)(v >> 8);
}

/* Slot 0 is solid red, slot 1 solid green, slot 2 half transparent (its left
 * half green, its right half index 0). */
static void build_tiles(void) {
  int i;
  for (i = 0; i < RW_TILE_PIXELS; i++) {
    g_tiles[i] = IDX_RED;
    g_tiles[RW_TILE_PIXELS + i] = IDX_GREEN;
    g_tiles[2 * RW_TILE_PIXELS + i] =
        (i % RW_TS) < RW_TS / 2 ? IDX_GREEN : RW_TRANSPARENT_INDEX;
  }
}

/* A 4x3 map: every cell lower slot 0, no upper tile, fully passable, player
 * in the middle. Individual tests then poke at the cells they care about. */
static void build_map(void) {
  int i;
  memset(g_map, 0, sizeof(g_map));
  memcpy(g_map, "N7WM", 4);
  g_map[4] = RW_FORMAT_VERSION;
  put_u16(g_map + 6, W);
  put_u16(g_map + 8, H);
  put_u16(g_map + 10, 1); /* start x */
  put_u16(g_map + 12, 1); /* start y */
  put_u16(g_map + 14, TILES);
  put_u16(g_map + 16, BLUE); /* backdrop */
  put_u16(g_map + 18, PAL_COUNT);
  put_u16(g_map + RW_MAP_HEADER_BYTES, 0); /* the transparent slot */
  put_u16(g_map + RW_MAP_HEADER_BYTES + 2, RED);
  put_u16(g_map + RW_MAP_HEADER_BYTES + 4, GREEN);
  for (i = 0; i < W * H; i++) {
    g_map[CELLS_AT + i] = 0;
    g_map[UPPER_AT + i] = RW_UPPER_NONE;
    set_passable(i % W, i / W,
                 RW_DIR_UP | RW_DIR_DOWN | RW_DIR_LEFT | RW_DIR_RIGHT);
  }
}

static void set_lower(int x, int y, unsigned slot) {
  g_map[CELLS_AT + y * W + x] = (uint8_t)slot;
}

static void set_upper(int x, int y, unsigned slot) {
  g_map[UPPER_AT + y * W + x] = (uint8_t)slot;
}

/* Two cells per byte, the even cell in the low nibble -- the packing the
 * exporter writes. */
static void set_passable(int x, int y, unsigned bits) {
  int cell = y * W + x;
  uint8_t* byte = &g_map[PASS_AT + (cell >> 1)];
  if (cell & 1)
    *byte = (uint8_t)((*byte & 0x0f) | (bits << 4));
  else
    *byte = (uint8_t)((*byte & 0xf0) | (bits & 0x0f));
}

static rw_status open_default(rw_map* m) {
  return rw_open(m, g_map, sizeof(g_map), g_tiles, sizeof(g_tiles));
}

static void test_open(void) {
  rw_map m;
  uint8_t bad[MAP_BYTES];

  check(open_default(&m) == RW_OK, "a well-formed map opens");
  check(m.width == W && m.height == H, "dimensions are read");
  check(m.tile_count == TILES, "tile count is read");
  check(m.player_x == 1 && m.player_y == 1, "start position is the player's");
  check(m.backdrop == BLUE, "backdrop is read");
  check(m.palette_count == PAL_COUNT, "palette count is read");
  check(rw_palette_colour(&m, IDX_RED) == RED, "a palette entry resolves");
  check(rw_palette_colour(&m, RW_TRANSPARENT_INDEX) == 0,
        "index 0 is transparent");
  check(rw_palette_colour(&m, PAL_COUNT) == 0,
        "an index past the palette is transparent, not a read past it");

  check(rw_open(&m, g_map, RW_MAP_HEADER_BYTES - 1, g_tiles, sizeof(g_tiles)) ==
            RW_ERR_SHORT_HEADER,
        "a truncated header is refused");

  memcpy(bad, g_map, sizeof(bad));
  bad[1] = 'X';
  check(rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_MAGIC,
        "wrong magic is refused");

  memcpy(bad, g_map, sizeof(bad));
  bad[4] = RW_FORMAT_VERSION + 1;
  check(
      rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_VERSION,
      "another format version is refused");

  memcpy(bad, g_map, sizeof(bad));
  put_u16(bad + 10, W); /* start x on the right edge, one past the last cell */
  check(
      rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_HEADER,
      "a start position outside the map is refused");

  memcpy(bad, g_map, sizeof(bad));
  put_u16(bad + 14, RW_MAX_TILES + 1);
  check(
      rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_HEADER,
      "an atlas too big to index in a byte is refused");

  /* The palette always holds at least its transparent slot, and can never
   * hold more entries than a one-byte index can reach. */
  memcpy(bad, g_map, sizeof(bad));
  put_u16(bad + 18, 0);
  check(
      rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_PALETTE,
      "an empty palette is refused");
  memcpy(bad, g_map, sizeof(bad));
  put_u16(bad + 18, RW_MAX_PALETTE + 1);
  check(
      rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_PALETTE,
      "a palette too big to index in a byte is refused");

  /* A palette the file does not actually carry must not push the cell
   * pointers past the end of the buffer. */
  memcpy(bad, g_map, sizeof(bad));
  put_u16(bad + 18, RW_MAX_PALETTE);
  check(rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) ==
            RW_ERR_MAP_TRUNCATED,
        "a palette bigger than the file is refused");

  /* The device's size cap: a map read into a buffer too small for it arrives
   * short, and must be refused rather than indexed past. */
  check(rw_open(&m, g_map, sizeof(g_map) - 1, g_tiles, sizeof(g_tiles)) ==
            RW_ERR_MAP_TRUNCATED,
        "a map bigger than the buffer is refused");
  check(rw_open(&m, g_map, sizeof(g_map), g_tiles, sizeof(g_tiles) - 1) ==
            RW_ERR_TILES_TRUNCATED,
        "an atlas bigger than the buffer is refused");
  check(rw_status_str(RW_ERR_MAGIC)[0] != '\0', "a failure has a reason");
}

static void test_move(void) {
  rw_map m;

  build_map();
  open_default(&m);
  check(rw_try_move(&m, 1, 0) == 1 && m.player_x == 2 && m.player_y == 1,
        "a step into a passable cell moves the player");
  check(rw_try_move(&m, 0, 0) == 0, "a zero step is not a move");

  /* Walking off the map is blocked even where the mask says the edge cell is
   * exitable that way. */
  build_map();
  open_default(&m);
  m.player_x = 0;
  check(rw_try_move(&m, -1, 0) == 0 && m.player_x == 0,
        "a step off the map edge is blocked");

  /* Both halves of the rule, one at a time: the cell being left must permit
   * the direction, and the target must permit the opposite one. */
  build_map();
  set_passable(1, 1, RW_DIR_UP | RW_DIR_DOWN | RW_DIR_LEFT); /* not right */
  open_default(&m);
  check(rw_try_move(&m, 1, 0) == 0 && m.player_x == 1,
        "a cell that cannot be left in that direction blocks the step");

  build_map();
  set_passable(2, 1, RW_DIR_UP | RW_DIR_DOWN | RW_DIR_RIGHT); /* not left */
  open_default(&m);
  check(rw_try_move(&m, 1, 0) == 0 && m.player_x == 1,
        "a cell that cannot be entered from that side blocks the step");

  build_map();
  open_default(&m);
  check(rw_passable_at(&m, -1, 0) == 0, "outside the map is impassable");

  /* Two cells share a byte, so a cell must not read its neighbour's nibble. */
  build_map();
  set_passable(0, 0, RW_DIR_UP);
  set_passable(1, 0, RW_DIR_LEFT | RW_DIR_RIGHT);
  set_passable(2, 0, 0);
  set_passable(3, 0, RW_DIR_DOWN);
  open_default(&m);
  check(rw_passable_at(&m, 0, 0) == RW_DIR_UP &&
            rw_passable_at(&m, 1, 0) == (RW_DIR_LEFT | RW_DIR_RIGHT) &&
            rw_passable_at(&m, 2, 0) == 0 &&
            rw_passable_at(&m, 3, 0) == RW_DIR_DOWN,
        "each cell reads its own passability nibble");
}

static void test_camera(void) {
  rw_map m;
  int cx, cy;

  build_map();
  open_default(&m);

  /* A view wider than the map pins to the origin rather than going negative. */
  rw_camera(&m, 8, 8, &cx, &cy);
  check(cx == 0 && cy == 0, "a view bigger than the map clamps to 0,0");

  rw_camera(&m, 2, 1, &cx, &cy);
  check(cx == 0 && cy == 1, "the view centres on the player");

  m.player_x = W - 1;
  rw_camera(&m, 2, 1, &cx, &cy);
  check(cx == W - 2, "the view stops at the right edge");
}

static void test_compose(void) {
  rw_map m;
  uint16_t out[RW_TILE_PIXELS];
  int i;
  int opaque = 1;

  build_map();
  set_upper(0, 0, 2); /* the half-transparent tile over lower slot 0 (red) */
  open_default(&m);

  rw_compose_cell(&m, 0, 0, out);
  check(out[0] == GREEN, "an upper tile's opaque pixels win over the lower");
  check(out[RW_TS - 1] == RED,
        "an upper tile's transparent pixels show the lower tile");
  for (i = 0; i < RW_TILE_PIXELS; i++)
    if ((out[i] & RW_OPAQUE) == 0)
      opaque = 0;
  check(opaque, "every composited pixel is opaque");

  /* A hole in the lower layer is the backdrop, not black -- this is what
   * makes an island map's sea look like sea. */
  build_map();
  set_lower(0, 0, 2); /* half-transparent */
  open_default(&m);
  rw_compose_cell(&m, 0, 0, out);
  check(out[RW_TS - 1] == BLUE, "a hole in the lower layer shows the backdrop");

  /* Nothing reads past the buffers for a cell (or a tile index) that is not
   * there: both composite as plain backdrop. */
  build_map();
  set_lower(0, 0, TILES + 7);
  open_default(&m);
  rw_compose_cell(&m, 0, 0, out);
  check(out[0] == BLUE, "an out-of-range tile index is backdrop");
  rw_compose_cell(&m, -1, 0, out);
  check(out[0] == BLUE, "a cell outside the map is backdrop");
}

int main(void) {
  build_tiles();
  build_map();

  test_open();
  test_move();
  test_camera();
  test_compose();

  printf("walk_core: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
