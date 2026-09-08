/* See rpg2k_walk_core.h. Freestanding C: no libc, no allocation, no I/O. */
#include "rpg2k_walk_core.h"

static uint16_t rd_u16(const uint8_t* p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

static int in_bounds(const rw_map* m, int x, int y) {
  return x >= 0 && y >= 0 && x < m->width && y < m->height;
}

static uint8_t cell_index(const uint8_t* base, const rw_map* m, int x, int y) {
  return base[(uint32_t)(y * m->width + x)];
}

rw_status rw_open(rw_map* m,
                  const uint8_t* map_bytes,
                  uint32_t map_len,
                  const uint8_t* tiles,
                  uint32_t tiles_len) {
  if (map_len < RW_MAP_HEADER_BYTES)
    return RW_ERR_SHORT_HEADER;
  if (map_bytes[0] != 'N' || map_bytes[1] != '7' || map_bytes[2] != 'W' ||
      map_bytes[3] != 'M')
    return RW_ERR_MAGIC;
  if (map_bytes[4] != RW_FORMAT_VERSION)
    return RW_ERR_VERSION;

  int w = rd_u16(map_bytes + 6);
  int h = rd_u16(map_bytes + 8);
  int sx = rd_u16(map_bytes + 10);
  int sy = rd_u16(map_bytes + 12);
  int entry_count = rd_u16(map_bytes + 14);
  uint16_t backdrop = rd_u16(map_bytes + 16);
  int palette_count = rd_u16(map_bytes + 18);
  int atlas_count = rd_u16(map_bytes + 20);
  int ab_len = map_bytes[22];
  int ab_period = map_bytes[23];
  int c_len = map_bytes[24];
  int c_period = map_bytes[25];
  /* Byte 5 was pad through v5; v6 repurposes it rather than growing the
   * header, since a version bump already means every export is regenerated. */
  int hero_present = map_bytes[5];

  if (w <= 0 || h <= 0 || sx >= w || sy >= h)
    return RW_ERR_HEADER;
  if (entry_count > RW_MAX_TILES || atlas_count > RW_MAX_TILES)
    return RW_ERR_HEADER;
  /* A clock with no steps, or one whose cycle is longer than an entry has
   * frames, would index past the entry. */
  if (ab_len < 1 || ab_len > RW_ANIM_MAX_FRAMES || ab_period < 1)
    return RW_ERR_HEADER;
  if (c_len < 1 || c_len > RW_ANIM_MAX_FRAMES || c_period < 1)
    return RW_ERR_HEADER;
  /* Index 0 is the transparent slot, so even an all-transparent map has one
   * entry; more than RW_MAX_PALETTE cannot be addressed by a one-byte
   * index. */
  if (palette_count < 1 || palette_count > RW_MAX_PALETTE)
    return RW_ERR_PALETTE;
  if (hero_present != 0 && hero_present != 1)
    return RW_ERR_HEADER;

  uint32_t cells = (uint32_t)w * (uint32_t)h;
  uint32_t palette_bytes = (uint32_t)palette_count * 2;
  uint32_t entry_bytes = (uint32_t)entry_count * RW_ENTRY_BYTES;
  uint32_t fixed = RW_MAP_HEADER_BYTES + palette_bytes + entry_bytes;
  if (map_len < fixed)
    return RW_ERR_MAP_TRUNCATED;
  if ((uint32_t)(map_len - fixed) < RW_MAP_CELL_BYTES(cells))
    return RW_ERR_MAP_TRUNCATED;
  {
    /* The hero's own frames sit in tiles.bin right after the ordinary atlas
     * -- one buffer, one length check, no second file. */
    uint32_t tiles_needed = (uint32_t)atlas_count * RW_TILE_BYTES;
    if (hero_present)
      tiles_needed += RW_HERO_FRAMES_BYTES;
    if (tiles_len < tiles_needed)
      return RW_ERR_TILES_TRUNCATED;
  }

  m->width = w;
  m->height = h;
  m->entry_count = entry_count;
  m->atlas_count = atlas_count;
  m->backdrop = backdrop;
  m->player_x = sx;
  m->player_y = sy;
  /* RPG2000's own New Game default facing (Game::Character#initialize's
   * direction default, Game::Party#initial_state) -- the exporter carries
   * no explicit facing to override it with, since a walk-map export has no
   * live game state, only the project's own initial party. */
  m->direction = RW_NUMPAD_DOWN;
  m->step_count = 0;
  m->hero_present = hero_present;
  m->hero_tiles = hero_present ? tiles + (uint32_t)atlas_count * RW_TILE_BYTES : 0;
  m->ab_len = ab_len;
  m->ab_period = ab_period;
  m->c_len = c_len;
  m->c_period = c_period;
  m->phase_ab = 0;
  m->phase_c = 0;
  m->palette = map_bytes + RW_MAP_HEADER_BYTES;
  m->palette_count = palette_count;
  m->entries = m->palette + palette_bytes;
  m->lower = m->entries + entry_bytes;
  m->upper = m->lower + cells;
  m->passable = m->upper + cells;
  m->tiles = tiles;

  /* Whether anything moves at all, answered once here so a still map -- 477
   * of Nepheshel's 543 -- costs the frame loop nothing. */
  m->animated = 0;
  {
    int i;
    for (i = 0; i < entry_count; i++) {
      if (m->entries[(uint32_t)i * RW_ENTRY_BYTES + 4] != RW_ANIM_STATIC) {
        m->animated = 1;
        break;
      }
    }
  }
  return RW_OK;
}

int rw_set_frame(rw_map* m, uint32_t frame) {
  int ab = (int)((frame / (uint32_t)m->ab_period) % (uint32_t)m->ab_len);
  int c = (int)((frame / (uint32_t)m->c_period) % (uint32_t)m->c_len);
  if (ab == m->phase_ab && c == m->phase_c)
    return 0;
  m->phase_ab = ab;
  m->phase_c = c;
  return 1;
}

uint8_t rw_entry_atlas(const rw_map* m, uint8_t entry) {
  const uint8_t* e;
  if ((int)entry >= m->entry_count)
    return 0;
  e = m->entries + (uint32_t)entry * RW_ENTRY_BYTES;
  switch (e[4]) {
    case RW_ANIM_WATER:
      return e[m->phase_ab];
    case RW_ANIM_BLOCK_C:
      return e[m->phase_c];
    default:
      return e[0];
  }
}

static int entry_moves(const rw_map* m, uint8_t entry) {
  if ((int)entry >= m->entry_count)
    return 0;
  return m->entries[(uint32_t)entry * RW_ENTRY_BYTES + 4] != RW_ANIM_STATIC;
}

int rw_cell_animated(const rw_map* m, int mx, int my) {
  uint8_t up;
  if (!m->animated || !in_bounds(m, mx, my))
    return 0;
  if (entry_moves(m, cell_index(m->lower, m, mx, my)))
    return 1;
  up = cell_index(m->upper, m, mx, my);
  return up != RW_UPPER_NONE && entry_moves(m, up);
}

const char* rw_status_str(rw_status status) {
  switch (status) {
    case RW_OK:
      return "ok";
    case RW_ERR_SHORT_HEADER:
      return "map.bin is too short";
    case RW_ERR_MAGIC:
      return "map.bin has the wrong magic";
    case RW_ERR_VERSION:
      return "map.bin is another format version";
    case RW_ERR_HEADER:
      return "map.bin header is out of range";
    case RW_ERR_PALETTE:
      return "map.bin has no usable palette";
    case RW_ERR_MAP_TRUNCATED:
      return "map.bin is bigger than this device";
    case RW_ERR_TILES_TRUNCATED:
      return "tiles.bin is bigger than this device";
  }
  return "unknown error";
}

uint16_t rw_palette_colour(const rw_map* m, uint8_t index) {
  if (index == RW_TRANSPARENT_INDEX || (int)index >= m->palette_count)
    return 0;
  return rd_u16(m->palette + (uint32_t)index * 2);
}

uint8_t rw_passable_at(const rw_map* m, int x, int y) {
  uint32_t cell;
  uint8_t packed;
  if (!in_bounds(m, x, y))
    return 0;
  /* Two cells to a byte: the even one in the low nibble, the odd one in the
   * high nibble, in the same order the exporter packs them. */
  cell = (uint32_t)(y * m->width + x);
  packed = m->passable[cell >> 1];
  return (uint8_t)((cell & 1u) ? (packed >> 4) : (packed & 0x0fu));
}

int rw_try_move(rw_map* m, int dx, int dy) {
  uint8_t leave, enter;
  int nx, ny, dir;

  if (dx < 0) {
    leave = RW_DIR_LEFT;
    enter = RW_DIR_RIGHT;
    dir = RW_NUMPAD_LEFT;
  } else if (dx > 0) {
    leave = RW_DIR_RIGHT;
    enter = RW_DIR_LEFT;
    dir = RW_NUMPAD_RIGHT;
  } else if (dy < 0) {
    leave = RW_DIR_UP;
    enter = RW_DIR_DOWN;
    dir = RW_NUMPAD_UP;
  } else if (dy > 0) {
    leave = RW_DIR_DOWN;
    enter = RW_DIR_UP;
    dir = RW_NUMPAD_DOWN;
  } else {
    return 0;
  }

  /* Bump-turn: face the attempted direction before the passability check,
   * same as real RPG2000, and leave it turned even when the step below
   * fails. */
  m->direction = dir;

  nx = m->player_x + dx;
  ny = m->player_y + dy;
  if (!in_bounds(m, nx, ny))
    return 0;
  if ((rw_passable_at(m, m->player_x, m->player_y) & leave) == 0)
    return 0;
  if ((rw_passable_at(m, nx, ny) & enter) == 0)
    return 0;

  m->player_x = nx;
  m->player_y = ny;
  m->step_count++;
  return 1;
}

void rw_camera(const rw_map* m,
               int view_w,
               int view_h,
               int* cam_x,
               int* cam_y) {
  int x = m->player_x - view_w / 2;
  int y = m->player_y - view_h / 2;
  if (x > m->width - view_w)
    x = m->width - view_w;
  if (y > m->height - view_h)
    y = m->height - view_h;
  if (x < 0)
    x = 0;
  if (y < 0)
    y = 0;
  *cam_x = x;
  *cam_y = y;
}

void rw_compose_cell(const rw_map* m, int mx, int my, uint16_t* out) {
  const uint8_t* lower = 0;
  const uint8_t* upper = 0;
  int i;

  if (in_bounds(m, mx, my)) {
    uint8_t lo = cell_index(m->lower, m, mx, my);
    uint8_t up = cell_index(m->upper, m, mx, my);
    /* A cell names an entry; the entry names the picture it shows *now*. */
    if ((int)lo < m->entry_count)
      lower = m->tiles + (uint32_t)rw_entry_atlas(m, lo) * RW_TILE_PIXELS;
    if (up != RW_UPPER_NONE && (int)up < m->entry_count)
      upper = m->tiles + (uint32_t)rw_entry_atlas(m, up) * RW_TILE_PIXELS;
  }

  for (i = 0; i < RW_TILE_PIXELS; i++) {
    /* Index 0 is the transparent slot, so "no pixel here" and "the palette
     * says nothing here" are the same test, once per layer. */
    uint8_t index = lower ? lower[i] : RW_TRANSPARENT_INDEX;
    uint16_t c;
    if (upper && upper[i] != RW_TRANSPARENT_INDEX)
      index = upper[i];
    c = rw_palette_colour(m, index);
    /* A hole is not black: the exporter reduced the map's parallax
     * background to this one colour, and it is what the genuine runtime
     * shows through an empty chip (an island map's whole sea, say). */
    out[i] = c ? c : (uint16_t)(m->backdrop | RW_OPAQUE);
  }
}

/* numpad direction -> row within a CharSet template (Game::CharSet::DIR_ROW:
 * up, right, down, left, top to bottom); an unrecognised value reads as
 * "down", the same fallback DIR_ROW's own `|| 2` applies. */
static int hero_dir_row(int direction) {
  switch (direction) {
    case RW_NUMPAD_UP:
      return 0;
    case RW_NUMPAD_RIGHT:
      return 1;
    case RW_NUMPAD_LEFT:
      return 3;
    default:
      return 2;
  }
}

void rw_compose_hero(const rw_map* m, int moving, uint16_t* out) {
  /* Neutral, one lean, neutral, the other lean -- Game::CharSet::WALK_
   * PATTERNS, the cycle a run of steps advances through. */
  static const int walk_patterns[RW_WALK_PATTERN_COUNT] = {1, 2, 1, 0};
  const uint8_t* frame;
  int pattern, row, i;

  if (!m->hero_present) {
    for (i = 0; i < RW_HERO_FRAME_PIXELS; i++)
      out[i] = 0;
    return;
  }

  pattern = moving ? walk_patterns[m->step_count % RW_WALK_PATTERN_COUNT] : 1;
  row = hero_dir_row(m->direction);
  frame = m->hero_tiles +
          (uint32_t)(row * RW_HERO_PATTERNS + pattern) * RW_HERO_FRAME_PIXELS;

  for (i = 0; i < RW_HERO_FRAME_PIXELS; i++) {
    /* Transparent stays 0 rather than resolving to the backdrop: a hero
     * frame draws over whatever the map already put there, not into a hole
     * that needs filling. */
    uint8_t index = frame[i];
    out[i] = index == RW_TRANSPARENT_INDEX ? 0 : rw_palette_colour(m, index);
  }
}

void rw_hero_screen_pos(const rw_map* m, int cam_x, int cam_y, int* x, int* y) {
  int tile_x = (m->player_x - cam_x) * RW_TS;
  int tile_y = (m->player_y - cam_y) * RW_TS;
  *x = tile_x - (RW_HERO_FRAME_W - RW_TS) / 2;
  *y = tile_y - (RW_HERO_FRAME_H - RW_TS);
}
