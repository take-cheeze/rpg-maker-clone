/* See rpg2k_walk_core.h. Freestanding C: no libc, no allocation, no I/O. */
#include "rpg2k_walk_core.h"

static uint16_t rd_u16(const uint8_t* p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

static int in_bounds(const rw_map* m, int x, int y) {
  return x >= 0 && y >= 0 && x < m->width && y < m->height;
}

static uint16_t cell_index(const uint8_t* base, const rw_map* m, int x, int y) {
  return rd_u16(base + (uint32_t)(y * m->width + x) * 2);
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
  int tile_count = rd_u16(map_bytes + 14);
  uint16_t backdrop = rd_u16(map_bytes + 16);
  int palette_count = rd_u16(map_bytes + 18);

  if (w <= 0 || h <= 0 || sx >= w || sy >= h)
    return RW_ERR_HEADER;
  /* Index 0 is the transparent slot, so even an all-transparent map has one
   * entry; more than RW_MAX_PALETTE cannot be addressed by a one-byte
   * index. */
  if (palette_count < 1 || palette_count > RW_MAX_PALETTE)
    return RW_ERR_PALETTE;

  uint32_t cells = (uint32_t)w * (uint32_t)h;
  uint32_t palette_bytes = (uint32_t)palette_count * 2;
  if (map_len < RW_MAP_HEADER_BYTES + palette_bytes)
    return RW_ERR_MAP_TRUNCATED;
  if (map_len - RW_MAP_HEADER_BYTES - palette_bytes <
      cells * RW_MAP_BYTES_PER_CELL)
    return RW_ERR_MAP_TRUNCATED;
  if (tiles_len < (uint32_t)tile_count * RW_TILE_BYTES)
    return RW_ERR_TILES_TRUNCATED;

  m->width = w;
  m->height = h;
  m->tile_count = tile_count;
  m->backdrop = backdrop;
  m->player_x = sx;
  m->player_y = sy;
  m->palette = map_bytes + RW_MAP_HEADER_BYTES;
  m->palette_count = palette_count;
  m->lower = m->palette + palette_bytes;
  m->upper = m->lower + cells * 2;
  m->passable = m->upper + cells * 2;
  m->tiles = tiles;
  return RW_OK;
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
  if (!in_bounds(m, x, y))
    return 0;
  return m->passable[y * m->width + x];
}

int rw_try_move(rw_map* m, int dx, int dy) {
  uint8_t leave, enter;
  int nx, ny;

  if (dx < 0) {
    leave = RW_DIR_LEFT;
    enter = RW_DIR_RIGHT;
  } else if (dx > 0) {
    leave = RW_DIR_RIGHT;
    enter = RW_DIR_LEFT;
  } else if (dy < 0) {
    leave = RW_DIR_UP;
    enter = RW_DIR_DOWN;
  } else if (dy > 0) {
    leave = RW_DIR_DOWN;
    enter = RW_DIR_UP;
  } else {
    return 0;
  }

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
    uint16_t lo = cell_index(m->lower, m, mx, my);
    uint16_t up = cell_index(m->upper, m, mx, my);
    if (lo < (uint16_t)m->tile_count)
      lower = m->tiles + (uint32_t)lo * RW_TILE_PIXELS;
    if (up != RW_UPPER_NONE && up < (uint16_t)m->tile_count)
      upper = m->tiles + (uint32_t)up * RW_TILE_PIXELS;
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
