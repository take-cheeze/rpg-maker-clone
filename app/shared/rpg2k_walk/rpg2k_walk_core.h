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
 * A tile pixel is one byte: an index into the map's own palette, whose
 * entries are ARGB1555 (bit 15 set means drawn, bits 14..0 are r5g5b5) and
 * whose entry 0 is the transparent slot. The palette is the source data's --
 * an RPG Maker chipset is a 256-colour image, and one map uses a subset --
 * so this costs no colour fidelity and halves the atlas, which is the
 * largest thing either device holds in RAM. A device converts a palette
 * entry to its own framebuffer format on the way out.
 *
 * Both files are little-endian, as are both targets (ARM); map.bin is read
 * byte-wise, so only the palette's own u16 entries would need swapping on a
 * big-endian port.
 */
#ifndef RPG2K_WALK_CORE_H
#define RPG2K_WALK_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RW_TS 16 /* chipset tile size, matches the exporter */
#define RW_TILE_PIXELS (RW_TS * RW_TS)

#define RW_FORMAT_VERSION 5
/* Up to and including the animation clocks; the palette follows, then the
 * entry table, then the cells. */
#define RW_MAP_HEADER_BYTES 26
#define RW_TILE_BYTES RW_TILE_PIXELS /* one palette index per pixel */

/* Bytes the cell arrays take for `cells` cells: one byte of lower-layer
 * atlas index, one of upper, and a *nibble* of passability -- four direction
 * bits is all a cell has, so two cells share a byte. */
#define RW_MAP_CELL_BYTES(cells) \
  ((uint32_t)(cells) * 2u + (((uint32_t)(cells) + 1u) / 2u))

/* An entry index is a byte and 0xFF is the "no upper tile" sentinel, so an
 * export may hold at most 255 entries, addressed 0..254; an atlas slot is a
 * byte inside an entry, so the atlas caps there too. */
#define RW_MAX_TILES 255

/* One entry: four atlas slots and the clock that moves through them. */
#define RW_ENTRY_BYTES 5
#define RW_ANIM_MAX_FRAMES 4

/* Which of RPG2000's animation clocks an entry follows. The exporter reads
 * both off mruby-rpg2k itself (Game::ChipsetLayout.anim_ab for the water
 * autotiles, .anim_c for the block-C animated tiles), so what a device does
 * here is index a table, not know the rules. */
#define RW_ANIM_STATIC 0
#define RW_ANIM_WATER 1
#define RW_ANIM_BLOCK_C 2

/* Palette index 0 is the transparent slot, so a palette holds at most 255
 * opaque colours. */
#define RW_TRANSPARENT_INDEX 0
#define RW_MAX_PALETTE 256

/* "no upper-layer tile here", written by the exporter for a blank chip. */
#define RW_UPPER_NONE 0xFFu
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
  RW_ERR_HEADER,         /* dimensions, start position or tile count bad */
  RW_ERR_PALETTE,        /* palette missing, or too big to index in a byte */
  RW_ERR_MAP_TRUNCATED,  /* map.bin did not fit the buffer it was read into */
  RW_ERR_TILES_TRUNCATED /* tiles.bin did not fit its buffer */
} rw_status;

typedef struct {
  int width, height;
  int entry_count;   /* cells name these */
  int atlas_count;   /* pictures in tiles.bin, named by an entry's frames */
  uint16_t backdrop; /* ARGB1555; what shows through a transparent pixel */
  int player_x, player_y;

  /* The two animation clocks, as the export measured them off the engine:
   * how many frames a step lasts and how many steps the cycle has. The
   * current step of each is what rw_set_frame moves. */
  int ab_len, ab_period;
  int c_len, c_period;
  int phase_ab, phase_c;
  int animated; /* 1 when any entry moves at all */

  const uint8_t* palette; /* palette_count ARGB1555 entries, little-endian */
  int palette_count;
  const uint8_t* entries;  /* entry_count * RW_ENTRY_BYTES */
  const uint8_t* lower;    /* width*height entry indices, one byte each */
  const uint8_t* upper;    /* same, with RW_UPPER_NONE for "no upper tile" */
  const uint8_t* passable; /* RW_DIR_* bits, two cells per byte */
  const uint8_t* tiles;    /* atlas_count * RW_TILE_PIXELS palette indices */
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
                  const uint8_t* tiles,
                  uint32_t tiles_len);

/* A short, printable reason for a failed rw_open. */
const char* rw_status_str(rw_status status);

/* One palette entry as ARGB1555. Index 0, and any index past the palette,
 * read as transparent. */
uint16_t rw_palette_colour(const rw_map* m, uint8_t index);

/*
 * Move the animation clocks to `frame`, RPG2000's own 60-a-second frame
 * counter. Returns 1 when a clock actually stepped, which is the platform's
 * cue to redraw -- and only the cells rw_cell_animated reports, since on a
 * typical map that is the water and nothing else.
 */
int rw_set_frame(rw_map* m, uint32_t frame);

/* The atlas slot an entry shows at the current phase. */
uint8_t rw_entry_atlas(const rw_map* m, uint8_t entry);

/* Whether either of a cell's layers moves with a clock. 0 outside the map. */
int rw_cell_animated(const rw_map* m, int mx, int my);

/* The passability bits of one cell (its nibble, unpacked); 0 for a cell
 * outside the map. */
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
