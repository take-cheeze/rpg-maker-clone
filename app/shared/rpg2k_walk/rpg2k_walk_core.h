/*
 * rpg2k_walk_core -- the platform-independent half of the minimal RPG Maker
 * 2000/2003 map-walking engine.
 *
 * This is NOT the mruby/RGSS engine the rest of this repo runs (desktop,
 * browser, PSP, Android): it is the small from-scratch C engine of ADR 61,
 * for devices where the interpreter and its gem stack cannot fit at all --
 * the iPod nano 7G's ~500 KB app-image ceiling, the Wio Terminal's 192 KB of
 * SRAM. All LCF parsing, autotile assembly, chipset compositing and
 * passability resolution happen once on the host, in
 * scripts/export_nano7_map.rb, using this repo's own pure-Ruby engine
 * sources; what is left -- and what lives here -- is reading two flat files
 * and indexing arrays.
 *
 * Nothing in this file talks to a screen, a filesystem, a clock or an input
 * device, and it allocates nothing: the platform loads both files into
 * buffers it owns and sized itself (which is what lets one device give the
 * atlas 128 KB and another 64 KB), then calls into here for movement,
 * camera and per-cell compositing. See app/nano7/rpg2k_walk (NanoApps) and
 * app/wio/src/walk_main.cxx (Arduino) for the two platform halves.
 *
 * Pixels are ARGB1555: bit 15 set means the pixel is drawn, bits 14..0 are
 * r5g5b5. A device converts to its own framebuffer format on the way out.
 * Both files are little-endian, as are both targets (ARM); tiles.bin is
 * indexed as uint16_t directly, so a big-endian port would have to swap it.
 */
#ifndef RPG2K_WALK_CORE_H
#define RPG2K_WALK_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RW_TS 16 /* chipset tile size, matches the exporter */
#define RW_TILE_PIXELS (RW_TS * RW_TS)

#define RW_FORMAT_VERSION 2
#define RW_MAP_HEADER_BYTES 18
#define RW_MAP_BYTES_PER_CELL 5 /* u16 lower + u16 upper + u8 passable */
#define RW_TILE_BYTES (RW_TILE_PIXELS * 2)

/* "no upper-layer tile here", written by the exporter for a blank chip. */
#define RW_UPPER_NONE 0xFFFFu
/* ARGB1555's alpha bit. */
#define RW_OPAQUE 0x8000u

/* Passability bits, matching DIR_BITS in the exporter (RPG2000's own numpad
 * direction convention, Game::ChipSet::DIR_BIT in mruby-rpg2k). */
#define RW_DIR_DOWN 0x01
#define RW_DIR_LEFT 0x02
#define RW_DIR_RIGHT 0x04
#define RW_DIR_UP 0x08

typedef enum {
  RW_OK = 0,
  RW_ERR_SHORT_HEADER,   /* fewer bytes than a header */
  RW_ERR_MAGIC,          /* not a map.bin */
  RW_ERR_VERSION,        /* a format this build does not read */
  RW_ERR_HEADER,         /* dimensions or start position out of range */
  RW_ERR_MAP_TRUNCATED,  /* map.bin did not fit the buffer it was read into */
  RW_ERR_TILES_TRUNCATED /* tiles.bin did not fit its buffer */
} rw_status;

typedef struct {
  int width, height;
  int tile_count;
  uint16_t backdrop; /* ARGB1555; what shows through a transparent pixel */
  int player_x, player_y;

  const uint8_t* lower; /* width*height u16, little-endian */
  const uint8_t* upper;
  const uint8_t* passable; /* width*height u8 of RW_DIR_* bits */
  const uint16_t* tiles;   /* tile_count * RW_TILE_PIXELS ARGB1555 pixels */
} rw_map;

/*
 * Point `m` at an already-loaded map.bin/tiles.bin pair. `map_len` and
 * `tiles_len` are the byte counts actually read, so a file larger than the
 * platform's buffer arrives short and is refused here rather than read past
 * -- which is also how a device states its own size caps: it gives the
 * buffers it can afford, and an oversized export simply does not load.
 * The buffers must outlive `m`; nothing is copied.
 */
rw_status rw_open(rw_map* m,
                  const uint8_t* map_bytes,
                  uint32_t map_len,
                  const uint16_t* tiles,
                  uint32_t tiles_len);

/* A short, printable reason for a failed rw_open. */
const char* rw_status_str(rw_status status);

/* The passability bits of one cell; 0 for a cell outside the map. */
uint8_t rw_passable_at(const rw_map* m, int x, int y);

/*
 * Step the player one cell, if RPG2000's own movement rule allows it: the
 * current cell must permit leaving in that direction AND the target cell
 * must permit entering from the opposite one (both halves of
 * Scene::Map#char_passable?, baked into the exported mask). `dx`/`dy` is one
 * of the four unit directions; a diagonal is not a move this engine makes.
 * Returns 1 when the player moved. There are no events to block a step --
 * this engine has no interpreter.
 */
int rw_try_move(rw_map* m, int dx, int dy);

/*
 * Top-left cell of a view `view_w` x `view_h` cells wide, centred on the
 * player and clamped to the map (a map smaller than the view pins to 0).
 */
void rw_camera(const rw_map* m, int view_w, int view_h, int* cam_x, int* cam_y);

/*
 * Composite one cell into `out` (RW_TILE_PIXELS ARGB1555 pixels): the upper
 * layer's opaque pixels over the lower layer's, every remaining hole filled
 * with the backdrop. Every output pixel is opaque, so a caller can blit it
 * without testing anything. An out-of-range cell or tile index composites as
 * plain backdrop rather than reading past the buffers.
 */
void rw_compose_cell(const rw_map* m, int mx, int my, uint16_t* out);

#ifdef __cplusplus
}
#endif

#endif /* RPG2K_WALK_CORE_H */
