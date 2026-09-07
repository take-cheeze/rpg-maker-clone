/*
 * Host unit test for the shared map-walk core (rpg2k_walk_core.c), run by
 * CTest as `walk_core`.
 *
 * The two devices this core runs on -- an iPod nano 7G under NanoApps and a
 * Wio Terminal under Arduino -- are outside CI: no emulator, no board, and
 * for the nano no toolchain either (ADR 61, ADR 7). The core is plain C with
 * no I/O, so the half of those firmwares that can actually be wrong in an
 * interesting way (format parsing, the palette, the animation clocks, the
 * movement rule, camera clamping, layer compositing) is exactly the half a
 * host compiler can run.
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

/* Palette: 0 is the transparent slot, then red and green, then twelve more
 * marker colours the hero-frame tests use (one per CharSet frame, so
 * compositing the "wrong" frame is a wrong colour, not a coincidentally
 * matching one). The backdrop is a direct colour rather than an index, so
 * blue is not in the palette. */
#define IDX_RED 1
#define IDX_GREEN 2
#define IDX_HERO_BASE 3 /* palette indices 3..14: one per hero frame 0..11 */
#define PAL_COUNT (IDX_HERO_BASE + RW_HERO_FRAME_COUNT)
#define RED (RW_OPAQUE | (31u << 10))
#define GREEN (RW_OPAQUE | (31u << 5))
#define BLUE (RW_OPAQUE | 31u)
/* Distinct, arbitrary opaque colours -- the exact hues don't matter, only
 * that hero frame k's is not frame j's. */
#define HERO_MARK(k) (uint16_t)(RW_OPAQUE | (((k) + 1) << 6) | ((k) + 1))

/* Entries: 0 static (atlas 0), 1 static (atlas 1), 2 water cycling 0,1,2,1
 * over the four atlas slots, 3 block-C cycling 0..3. */
#define ENTRIES 4
#define E_RED 0
#define E_GREEN 1
#define E_WATER 2
#define E_BLOCK_C 3
#define AB_LEN 4
#define AB_PERIOD 24 /* what anim_ab does at animation_speed 0 */
#define C_LEN 4
#define C_PERIOD 6

#define PAL_BYTES (PAL_COUNT * 2)
#define ENTRY_BYTES (ENTRIES * RW_ENTRY_BYTES)
#define MAP_BYTES \
  (RW_MAP_HEADER_BYTES + PAL_BYTES + ENTRY_BYTES + RW_MAP_CELL_BYTES(W * H))
#define ENTRIES_AT (RW_MAP_HEADER_BYTES + PAL_BYTES)
#define CELLS_AT (ENTRIES_AT + ENTRY_BYTES)
#define UPPER_AT (CELLS_AT + W * H)
#define PASS_AT (UPPER_AT + W * H)

/* Room for the ordinary atlas plus the hero frames, whether or not a given
 * test's map actually turns hero_present on -- the extra tail bytes are
 * simply never read when it doesn't (rw_open only checks tiles_len against
 * what the header actually asks for). */
#define HERO_FRAME_AT(k) (TILES * RW_TILE_PIXELS + (k) * RW_HERO_FRAME_PIXELS)
#define TILES_BYTES (TILES * RW_TILE_PIXELS + RW_HERO_FRAMES_BYTES)

static uint8_t g_map[MAP_BYTES];
static uint8_t g_tiles[TILES_BYTES];

static void set_passable(int x, int y, unsigned bits);
static void set_entry(int entry,
                      unsigned klass,
                      unsigned f0,
                      unsigned f1,
                      unsigned f2,
                      unsigned f3);

static void put_u16(uint8_t* p, unsigned v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)(v >> 8);
}

/* Slot 0 is solid red, slot 1 solid green, slot 2 half transparent (its left
 * half green, its right half index 0). Also lays down the twelve hero
 * frames in the tail of g_tiles, each one solid marker colour k except
 * frame 7 (row 2 "down", pattern 1 "standing"), whose first pixel is
 * transparent instead -- the one hero test that isn't a flat colour check. */
static void build_tiles(void) {
  int i, k;
  for (i = 0; i < RW_TILE_PIXELS; i++) {
    g_tiles[i] = IDX_RED;
    g_tiles[RW_TILE_PIXELS + i] = IDX_GREEN;
    g_tiles[2 * RW_TILE_PIXELS + i] =
        (i % RW_TS) < RW_TS / 2 ? IDX_GREEN : RW_TRANSPARENT_INDEX;
  }
  for (k = 0; k < RW_HERO_FRAME_COUNT; k++) {
    int base = HERO_FRAME_AT(k);
    for (i = 0; i < RW_HERO_FRAME_PIXELS; i++)
      g_tiles[base + i] = (uint8_t)(IDX_HERO_BASE + k);
    if (k == 7)
      g_tiles[base] = RW_TRANSPARENT_INDEX;
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
  put_u16(g_map + 14, ENTRIES);
  put_u16(g_map + 16, BLUE); /* backdrop */
  put_u16(g_map + 18, PAL_COUNT);
  put_u16(g_map + 20, TILES);
  g_map[22] = AB_LEN;
  g_map[23] = AB_PERIOD;
  g_map[24] = C_LEN;
  g_map[25] = C_PERIOD;
  put_u16(g_map + RW_MAP_HEADER_BYTES, 0); /* the transparent slot */
  put_u16(g_map + RW_MAP_HEADER_BYTES + 2, RED);
  put_u16(g_map + RW_MAP_HEADER_BYTES + 4, GREEN);
  {
    int k;
    for (k = 0; k < RW_HERO_FRAME_COUNT; k++)
      put_u16(g_map + RW_MAP_HEADER_BYTES + (IDX_HERO_BASE + k) * 2,
              HERO_MARK(k));
  }
  /* hero_present (byte 5) stays 0 from the memset above; set_hero_present
   * turns it on for the tests that need it. */
  set_entry(E_RED, RW_ANIM_STATIC, 0, 0, 0, 0);
  set_entry(E_GREEN, RW_ANIM_STATIC, 1, 1, 1, 1);
  /* The ping-pong Game::ChipsetLayout.anim_ab walks for animation_type 0:
   * slots 0,1,2,1, so phases 1 and 3 show the same picture. */
  set_entry(E_WATER, RW_ANIM_WATER, 0, 1, 2, 1);
  set_entry(E_BLOCK_C, RW_ANIM_BLOCK_C, 0, 1, 2, 0);
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

static void set_hero_present(int present) {
  g_map[5] = (uint8_t)present;
}

static void set_entry(int entry,
                      unsigned klass,
                      unsigned f0,
                      unsigned f1,
                      unsigned f2,
                      unsigned f3) {
  uint8_t* e = &g_map[ENTRIES_AT + entry * RW_ENTRY_BYTES];
  e[0] = (uint8_t)f0;
  e[1] = (uint8_t)f1;
  e[2] = (uint8_t)f2;
  e[3] = (uint8_t)f3;
  e[4] = (uint8_t)klass;
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
  check(m.entry_count == ENTRIES, "entry count is read");
  check(m.atlas_count == TILES, "atlas count is read");
  check(m.ab_len == AB_LEN && m.ab_period == AB_PERIOD && m.c_len == C_LEN &&
            m.c_period == C_PERIOD,
        "both animation clocks are read");
  check(m.animated == 1, "a map with a moving entry says so");
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
      "more entries than a byte can name is refused");

  memcpy(bad, g_map, sizeof(bad));
  put_u16(bad + 20, RW_MAX_TILES + 1);
  check(
      rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_HEADER,
      "an atlas too big to index in a byte is refused");

  /* A clock that never steps would divide by zero; one whose cycle is longer
   * than an entry has frames would read past the entry. */
  memcpy(bad, g_map, sizeof(bad));
  bad[23] = 0;
  check(
      rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_HEADER,
      "a zero-length animation period is refused");
  memcpy(bad, g_map, sizeof(bad));
  bad[24] = RW_ANIM_MAX_FRAMES + 1;
  check(
      rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_HEADER,
      "a cycle longer than an entry's frames is refused");

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
  check(rw_open(&m, g_map, sizeof(g_map), g_tiles, TILES * RW_TILE_PIXELS - 1) ==
            RW_ERR_TILES_TRUNCATED,
        "an atlas bigger than the buffer is refused");
  check(rw_status_str(RW_ERR_MAGIC)[0] != '\0', "a failure has a reason");

  /* hero_present (byte 5) is a bool, not a general byte, and a truncated
   * hero region is caught the same way an atlas one is. */
  memcpy(bad, g_map, sizeof(bad));
  bad[5] = 2;
  check(rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_ERR_HEADER,
        "a hero_present byte that is not 0 or 1 is refused");

  memcpy(bad, g_map, sizeof(bad));
  bad[5] = 1;
  check(rw_open(&m, bad, sizeof(bad), g_tiles, TILES * RW_TILE_PIXELS) ==
            RW_ERR_TILES_TRUNCATED,
        "a hero export with no room for its frames in the tiles buffer is "
        "refused");
  check(rw_open(&m, bad, sizeof(bad), g_tiles, sizeof(g_tiles)) == RW_OK,
        "the same export opens once the buffer has room for the hero frames");
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

  /* RPG2000's own bump-turn (Scene::Map#step_movement): a blocked step still
   * turns the player to face it, and only a successful one counts toward
   * the walk-cycle pattern. */
  build_map();
  open_default(&m);
  check(m.direction == RW_NUMPAD_DOWN, "the player starts facing down");
  check(rw_try_move(&m, 1, 0) == 1 && m.direction == RW_NUMPAD_RIGHT,
        "a successful step turns to face it");
  check(m.step_count == 1, "a successful step counts toward the walk cycle");

  build_map();
  set_passable(1, 1, RW_DIR_UP | RW_DIR_DOWN | RW_DIR_LEFT); /* not right */
  open_default(&m);
  check(rw_try_move(&m, 1, 0) == 0 && m.direction == RW_NUMPAD_RIGHT,
        "a blocked step still turns to face it");
  check(m.step_count == 0, "a blocked step does not count toward the walk cycle");

  build_map();
  open_default(&m);
  m.player_x = 0;
  check(rw_try_move(&m, -1, 0) == 0 && m.direction == RW_NUMPAD_LEFT,
        "walking off the map edge still turns to face that way");
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
  /* Entry 3's phase-0 slot is atlas 0 (red); make an entry that is the
   * half-transparent picture instead, laid over the red lower tile. */
  set_entry(E_BLOCK_C, RW_ANIM_STATIC, 2, 2, 2, 2);
  set_upper(0, 0, E_BLOCK_C);
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
  set_entry(E_GREEN, RW_ANIM_STATIC, 2, 2, 2, 2); /* half-transparent */
  set_lower(0, 0, E_GREEN);
  open_default(&m);
  rw_compose_cell(&m, 0, 0, out);
  check(out[RW_TS - 1] == BLUE, "a hole in the lower layer shows the backdrop");

  /* Nothing reads past the buffers for a cell (or a tile index) that is not
   * there: both composite as plain backdrop. */
  build_map();
  set_lower(0, 0, ENTRIES + 7);
  open_default(&m);
  rw_compose_cell(&m, 0, 0, out);
  check(out[0] == BLUE, "an out-of-range entry index is backdrop");
  rw_compose_cell(&m, -1, 0, out);
  check(out[0] == BLUE, "a cell outside the map is backdrop");
}

/* The clocks: what a device gets for advancing a frame counter. */
static void test_animation(void) {
  rw_map m;
  uint16_t out[RW_TILE_PIXELS];

  build_map();
  set_lower(0, 0, E_WATER);
  set_lower(1, 0, E_RED);
  open_default(&m);

  check(rw_entry_atlas(&m, E_WATER) == 0, "phase 0 shows the first frame");
  check(rw_cell_animated(&m, 0, 0) == 1, "a water cell reports as moving");
  check(rw_cell_animated(&m, 1, 0) == 0, "a still cell does not");
  check(rw_cell_animated(&m, -1, 0) == 0, "a cell outside the map does not");

  /* Nothing moves inside a step -- and "inside" means inside the *faster*
   * clock's step, since the block-C one has stepped three times by the time
   * the water's first one is due. */
  check(rw_set_frame(&m, 0) == 0, "frame 0 is where the clocks already are");
  check(rw_set_frame(&m, C_PERIOD - 1) == 0,
        "part way through the shorter step is not a step");
  /* ...and the block-C clock, being faster, steps first. */
  check(rw_set_frame(&m, C_PERIOD) == 1, "the faster clock steps on its own");
  check(rw_entry_atlas(&m, E_WATER) == 0,
        "the water is unmoved by the block-C clock");
  check(rw_entry_atlas(&m, E_BLOCK_C) == 1, "the block-C tile moved");

  check(rw_set_frame(&m, AB_PERIOD) == 1,
        "the water clock steps at its period");
  check(rw_entry_atlas(&m, E_WATER) == 1, "the water is on its second frame");
  check(rw_entry_atlas(&m, E_RED) == 0, "a static entry never moves");

  /* The ping-pong: phases 1 and 3 are the same picture, phase 4 is back to
   * the start. */
  rw_set_frame(&m, AB_PERIOD * 2);
  check(rw_entry_atlas(&m, E_WATER) == 2, "third phase");
  rw_set_frame(&m, AB_PERIOD * 3);
  check(rw_entry_atlas(&m, E_WATER) == 1,
        "the fourth phase repeats the second");
  rw_set_frame(&m, AB_PERIOD * 4);
  check(rw_entry_atlas(&m, E_WATER) == 0, "the cycle wraps");

  /* A composited cell follows the clock, and a huge frame number (a device
   * that has been on for a day) still lands inside the cycle. */
  rw_set_frame(&m, AB_PERIOD);
  rw_compose_cell(&m, 0, 0, out);
  check(out[0] == GREEN, "the composited cell shows the moved frame");
  rw_set_frame(&m, 0xfffffff0u);
  check(rw_entry_atlas(&m, E_WATER) < TILES,
        "a far-future frame stays in range");

  /* A map with nothing animated says so, and then no clock ever reports a
   * step worth redrawing for. */
  build_map();
  set_entry(E_WATER, RW_ANIM_STATIC, 0, 0, 0, 0);
  set_entry(E_BLOCK_C, RW_ANIM_STATIC, 0, 0, 0, 0);
  open_default(&m);
  check(m.animated == 0, "a map with no moving entry says so");
  check(rw_cell_animated(&m, 0, 0) == 0, "and no cell claims to move");
}

/* A frame's own solid marker colour, except position 0 of frame 7 (row 2
 * "down", pattern 1 "standing"), which build_tiles left transparent. */
static int hero_frame_matches(const uint16_t* out, int frame) {
  int i;
  for (i = 0; i < RW_HERO_FRAME_PIXELS; i++) {
    uint16_t want = (frame == 7 && i == 0) ? 0 : HERO_MARK(frame);
    if (out[i] != want)
      return 0;
  }
  return 1;
}

/* The party leader's own CharSet (ADR 95): which of the 12 exported frames
 * RPG2000's facing/walk-cycle rule picks, and that a hero-less export draws
 * nothing rather than something wrong. */
static void test_hero(void) {
  rw_map m;
  uint16_t out[RW_HERO_FRAME_PIXELS];
  int i, x, y;

  /* No hero was exported: every pixel is transparent regardless of facing or
   * motion, so a caller that blits unconditionally simply draws nothing. */
  build_map();
  open_default(&m);
  check(m.hero_present == 0, "a map with no exported hero says so");
  rw_compose_hero(&m, 0, out);
  rw_compose_hero(&m, 1, out);
  for (i = 0; i < RW_HERO_FRAME_PIXELS && out[i] == 0; i++) {
  }
  check(i == RW_HERO_FRAME_PIXELS,
        "a hero-less export composites as fully transparent");

  build_map();
  set_hero_present(1);
  open_default(&m);
  check(m.hero_present == 1, "a map with an exported hero says so");

  /* Standing (not moving) is always pattern 1, in every direction -- the
   * default facing (down) is frame 7, the one build_tiles gave a
   * transparent pixel. */
  rw_compose_hero(&m, 0, out);
  check(hero_frame_matches(out, 7),
        "standing, facing down (the default), shows frame 7");
  check(out[0] == 0,
        "a transparent source pixel stays transparent, not the backdrop");

  m.direction = RW_NUMPAD_UP;
  rw_compose_hero(&m, 0, out);
  check(hero_frame_matches(out, 1), "standing, facing up, shows frame 1");

  m.direction = RW_NUMPAD_RIGHT;
  rw_compose_hero(&m, 0, out);
  check(hero_frame_matches(out, 4), "standing, facing right, shows frame 4");

  m.direction = RW_NUMPAD_LEFT;
  rw_compose_hero(&m, 0, out);
  check(hero_frame_matches(out, 10), "standing, facing left, shows frame 10");

  /* Moving cycles the walk pattern with step_count: neutral, one lean,
   * neutral, the other lean (Game::CharSet::WALK_PATTERNS), facing down. */
  m.direction = RW_NUMPAD_DOWN;
  m.step_count = 0;
  rw_compose_hero(&m, 1, out);
  check(hero_frame_matches(out, 7), "step 0 is still pattern 1 (neutral)");
  m.step_count = 1;
  rw_compose_hero(&m, 1, out);
  check(hero_frame_matches(out, 8), "step 1 is pattern 2 (a lean)");
  m.step_count = 2;
  rw_compose_hero(&m, 1, out);
  check(hero_frame_matches(out, 7), "step 2 is pattern 1 again (neutral)");
  m.step_count = 3;
  rw_compose_hero(&m, 1, out);
  check(hero_frame_matches(out, 6), "step 3 is pattern 0 (the other lean)");
  m.step_count = 4;
  rw_compose_hero(&m, 1, out);
  check(hero_frame_matches(out, 7), "step 4 wraps the cycle back to step 0");

  /* The screen anchor: centred over the tile horizontally, flush with its
   * bottom -- Scene::Map#render's own `px - (WIDTH-TILE)/2, py -
   * (HEIGHT-TILE)`, for a player at (1, 1) and a camera at (0, 0). */
  rw_hero_screen_pos(&m, 0, 0, &x, &y);
  check(x == 1 * RW_TS - (RW_HERO_FRAME_W - RW_TS) / 2,
        "the sprite is centred over its tile horizontally");
  check(y == 1 * RW_TS - (RW_HERO_FRAME_H - RW_TS),
        "the sprite's bottom is flush with its tile's");
}

int main(void) {
  build_tiles();
  build_map();

  test_open();
  test_move();
  test_camera();
  test_compose();
  test_animation();
  test_hero();

  printf("walk_core: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
