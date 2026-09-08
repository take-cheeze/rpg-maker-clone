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

/* A CharSet frame's pixel geometry, matching Game::CharSet::WIDTH/HEIGHT in
 * mruby-rpg2k: wider and taller than a tile, so the hero draws centred over
 * it horizontally and anchored to its bottom -- see rw_hero_screen_pos. Four
 * directions (down/left/right/up) by three walk-cycle patterns (RPG2000's
 * own numbering: 1 is standing/neutral, 0 and 2 are the two lean poses
 * either side of it -- see RW_WALK_PATTERN_COUNT below for the cycle
 * that walks through them). */
#define RW_HERO_FRAME_W 24
#define RW_HERO_FRAME_H 32
#define RW_HERO_FRAME_PIXELS (RW_HERO_FRAME_W * RW_HERO_FRAME_H)
#define RW_HERO_DIRS 4
#define RW_HERO_PATTERNS 3
#define RW_HERO_FRAME_COUNT (RW_HERO_DIRS * RW_HERO_PATTERNS)
#define RW_HERO_FRAMES_BYTES (RW_HERO_FRAME_COUNT * RW_HERO_FRAME_PIXELS)

/* An event sprite's frame is the same CharSet geometry as the hero's --
 * events with a "chip" (chipset-tile) graphic instead of a CharSet, or no
 * graphic at all, are not exported at all (see rpg2k_walk_core.c's own
 * v7 format note and scripts/export_nano7_map.rb) -- so no separate
 * dimensions are needed. */
#define RW_EVENT_FRAME_W RW_HERO_FRAME_W
#define RW_EVENT_FRAME_H RW_HERO_FRAME_H
#define RW_EVENT_FRAME_PIXELS RW_HERO_FRAME_PIXELS

/* One event: its map cell, which precomposited frame it shows, and which of
 * RPG2000's three draw layers it belongs to (RW_EVENT_LAYER_*, matching
 * MAP_EVENT_PAGE field 34's own 0/1/2). */
#define RW_EVENT_BYTES 4

#define RW_EVENT_LAYER_BELOW 0 /* always drawn under the hero */
#define RW_EVENT_LAYER_SAME 1  /* under or over, by row -- see below */
#define RW_EVENT_LAYER_ABOVE 2 /* always drawn over the hero */

/* A frame index is a byte, the same reasoning as RW_MAX_TILES for the
 * ordinary atlas -- this is the format's own ceiling, not any one target's;
 * see scripts/export_nano7_map.rb's own TARGETS for the smaller, real
 * per-device budget each one actually exports within. */
#define RW_MAX_EVENT_FRAMES 255

#define RW_FORMAT_VERSION 7
/* Up to and including event_frame_count; the palette follows, then the
 * entry table, then the event table, then the cells. */
#define RW_MAP_HEADER_BYTES 29
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

/* RPG2000's own numpad-direction values (distinct from the RW_DIR_* bitmask
 * above): rw_map::direction and a CharSet frame's row both use these, the
 * same values Game::CharSet::DIR_ROW keys on. */
#define RW_NUMPAD_DOWN 2
#define RW_NUMPAD_LEFT 4
#define RW_NUMPAD_RIGHT 6
#define RW_NUMPAD_UP 8

/* RPG2000's walk-cycle pattern for each of the 4 phases a step advances
 * through (Game::CharSet::WALK_PATTERNS): neutral, one lean, neutral, the
 * other lean -- so a walk that stops on an odd step still lands on a real
 * mid-stride pose, matching the genuine renderer's own cycle. Standing
 * (not moving) always shows the neutral pose, pattern 1. */
#define RW_WALK_PATTERN_COUNT 4

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
  int direction; /* RW_NUMPAD_*; RPG2000 turns to face a blocked step too */
  unsigned step_count; /* successful steps taken; drives the walk pattern */

  /* The party leader's own CharSet, precomposited the same way the atlas
   * is (palette indices into the map's own palette). 0 when the project's
   * initial party has no leader or the leader carries no CharSet -- an empty
   * map export, or one with an odd custom title-screen party setup. */
  int hero_present;
  const uint8_t* hero_tiles; /* RW_HERO_FRAME_COUNT * RW_HERO_FRAME_PIXELS */

  /* Map events with a CharSet graphic on their own initially-active page
   * (see rw_compose_event's own doc comment) -- one precomposited frame
   * each, picked once at export time the same way the hero's twelve are,
   * not twelve per event, since nothing here simulates a page's own
   * animation type or move route (see the v7 format note in
   * rpg2k_walk_core.c). event_frame_count many distinct frames, shared
   * across event_count events by index the same way the ordinary tile
   * atlas is shared across cells. */
  int event_count;
  int event_frame_count;
  const uint8_t* events;      /* event_count * RW_EVENT_BYTES */
  const uint8_t* event_tiles; /* event_frame_count * RW_EVENT_FRAME_PIXELS */

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
 *
 * Always turns `direction` to face (dx, dy) first, even when the step is
 * blocked -- RPG2000's own bump-turn (Scene::Map#step_movement sets
 * @state.direction before its passability check, and never reverts it on a
 * blocked step). A successful step also advances step_count, which picks
 * the hero's walk-cycle pattern.
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

/*
 * Composite the hero's current CharSet frame into `out` (RW_HERO_FRAME_PIXELS
 * ARGB1555 pixels, RW_HERO_FRAME_W wide): the frame RPG2000's own facing and
 * walk-cycle rule picks -- rw_try_move's bump-turn for direction, `moving`
 * (a direction currently held, the caller's own input state) and step_count
 * for the pattern (standing when `moving` is 0). A transparent source pixel
 * composites as 0 rather than the backdrop -- unlike rw_compose_cell, a hero
 * frame draws *over* whatever the map already put there, so a caller blits
 * it with a per-pixel skip test, not unconditionally. When no hero was
 * exported (hero_present is 0), every pixel is 0 and a caller that blits
 * unconditionally simply draws nothing.
 */
void rw_compose_hero(const rw_map* m, int moving, uint16_t* out);

/*
 * The hero sprite's top-left screen pixel for a viewport whose own top-left
 * cell is (cam_x, cam_y): centred horizontally over the player's tile and
 * anchored to its bottom, matching the genuine renderer's own
 * `px - (WIDTH-TILE)/2, py - (HEIGHT-TILE)` (Scene::Map#render). Pixels, not
 * cells -- unlike rw_camera's cam_x/cam_y -- and may fall outside the
 * viewport (a caller must clip), since the sprite overhangs its tile on
 * every side.
 */
void rw_hero_screen_pos(const rw_map* m, int cam_x, int cam_y, int* x, int* y);

/*
 * Composite event `index`'s single precomposited frame into `out`
 * (RW_EVENT_FRAME_PIXELS ARGB1555 pixels, RW_EVENT_FRAME_W wide). Unlike
 * rw_compose_hero, there is no live facing or walk-cycle to pick between --
 * the export already chose the one frame this event's initially-active page
 * would show (see the format note in rpg2k_walk_core.c) -- so this is a
 * straight palette-indexed copy, transparent staying 0 the same way a hero
 * frame's does (an event sprite draws *over* the map too). An out-of-range
 * `index` composites as fully transparent rather than reading past the
 * buffers.
 */
void rw_compose_event(const rw_map* m, int index, uint16_t* out);

/*
 * Event `index`'s top-left screen pixel, for a viewport whose own top-left
 * cell is (cam_x, cam_y) -- the same centred-horizontally,
 * bottom-anchored-to-its-tile anchor rw_hero_screen_pos uses, at the
 * event's own map cell rather than the player's. Pixels, not cells, and may
 * fall outside the viewport (a caller must clip), same as the hero's.
 */
void rw_event_screen_pos(const rw_map* m,
                         int index,
                         int cam_x,
                         int cam_y,
                         int* x,
                         int* y);

/* Event `index`'s own draw layer (RW_EVENT_LAYER_*); RW_EVENT_LAYER_BELOW
 * for an out-of-range index. */
int rw_event_layer(const rw_map* m, int index);

/*
 * Whether event `index` belongs in the group a caller draws *before* the
 * hero (so the hero, and anything from rw_event_before_hero's own 0 group,
 * draws over it) this frame -- RW_EVENT_LAYER_BELOW always does,
 * RW_EVENT_LAYER_ABOVE never does, and RW_EVENT_LAYER_SAME depends on
 * whether the event's own row is above the player's, matching the genuine
 * renderer's own event_target_buffer split (Scene::Map). An out-of-range
 * index reads as 1 (drawn before/under, the harmless default -- nothing
 * calls this with one in practice, since a caller loops 0..event_count).
 */
int rw_event_before_hero(const rw_map* m, int index);

#ifdef __cplusplus
}
#endif

#endif /* RPG2K_WALK_CORE_H */
