// Wio Terminal firmware: walk a real RPG Maker 2000/2003 map, with no mruby.
//
// The `wio` environment's roadmap (docs/adr/0007) puts the RPG2k runtime on
// this board by linking the interpreter and streaming assets off the SD card,
// and stalls on the same wall every time: 192 KB of SRAM and 512 KB of
// internal flash against a gem stack whose *assets alone* are read as
// multi-megabyte strings today. This environment takes the other route, the
// one the iPod nano 7G port had to take (docs/adr/0061, docs/adr/0091): move
// the whole engine to the host. scripts/export_nano7_map.rb does the LCF
// parsing, autotile assembly, chipset compositing and passability resolution
// once, with this repo's own pure-Ruby engine sources, and writes two flat
// files; what runs here is app/shared/rpg2k_walk/rpg2k_walk_core.c -- the same
// C the nano 7G app runs -- plus the board wiring in this file.
//
// So this is a second, much smaller engine, not the `wio` env's firmware with
// pieces disabled: no LVGL, no interpreter, no RGSS, and nothing this repo
// builds for the desktop. It walks a map -- with its water animating on
// RPG2000's own clock (docs/adr/0094), the player drawn as the project's own
// initial party leader (docs/adr/0096) when one was exported, and any map
// event with a CharSet graphic on its own initially-active page drawn as a
// static sprite too (docs/adr/0102) -- but it does not play the game.
//
// Board half only, and all of it is here: the SD card, the LCD, the 5-way
// switch, and the frame timing.

#include <Arduino.h>
#include <SPI.h>
#include <Seeed_FS.h>
#include <TFT_eSPI.h>

#include "SD/Seeed_SD.h"

#include "../../shared/rpg2k_walk/rpg2k_walk_core.h"

// The card's chip select and SPI bus. The Wio Terminal's own variant defines
// both; Seeed_Arduino_FS does not, and its examples define them by hand, so
// spell out the same fallback rather than depend on which side supplies it.
#ifndef SDCARD_SS_PIN
#define SDCARD_SS_PIN 1
#endif
#ifndef SDCARD_SPI
#define SDCARD_SPI SPI
#endif

namespace {

// This board's caps: the sizes of the two buffers below, and so the largest
// export it can load (rw_open refuses anything that does not fit rather than
// reading past them, and the exporter's `--target wio` refuses to write one).
//
// SRAM is the whole budget here -- 192 KB, no external RAM, nothing to spill
// to (docs/adr/0007's own headline constraint). These caps spend ~114.5 KB of
// it:
//
//   map.bin   29 + 256*2 + 192*5 + 1024*4 + 128*128*2.5 =  46,557 B
//   tiles.bin      192*16*16 + 12*24*32 + 16*24*32       =  70,656 B
//
// (the 12*24*32 is the hero's own frames, docs/adr/0096; the 16*24*32 is the
// event-sprite atlas, docs/adr/0102 -- both fixed costs whether or not a
// given export actually carries any, reserved unconditionally the same way
// the nano app does) leaving ~77.5 KB for the Arduino core, the SD and LCD
// drivers, the stack and this file's own statics. The map bound has doubled
// twice as the format
// shrank -- 64x64 when a tile pixel was 16-bit, 96x96 once it became a
// palette index (docs/adr/0092), 128x128 now a cell costs 2.5 bytes rather
// than 5 (docs/adr/0093) -- so this board now takes exactly the map sizes the
// iPod nano 7G does, in less SRAM than 64x64 cost it two revisions ago. Only
// the atlas cap still differs (192 here, 255 there). Still deliberately
// conservative; raising it is a two-line change once a real build reports
// what the drivers actually take.
constexpr int kMapMaxW = 128;
constexpr int kMapMaxH = 128;
constexpr int kMaxTiles = 192;
// Mirrors export_nano7_map.rb's own `wio` target max_event_frames/max_events
// -- see that file's own comment for the RAM budget and real-data numbers
// behind these (real worst case in the Nepheshel test bed: 256 events, 12
// distinct frames, on its most event-heavy map).
constexpr int kMaxEventFrames = 16;
constexpr int kMaxEvents = 1024;

constexpr uint32_t kMapBytes = RW_MAP_HEADER_BYTES + RW_MAX_PALETTE * 2 +
                               kMaxTiles * RW_ENTRY_BYTES +
                               (uint32_t)kMaxEvents * RW_EVENT_BYTES +
                               RW_MAP_CELL_BYTES(kMapMaxW * kMapMaxH);

// Where the exported pair lives on the microSD card.
constexpr char kMapPath[] = "/RPG2kWalk/map.bin";
constexpr char kTilesPath[] = "/RPG2kWalk/tiles.bin";

// One step per this long while a direction is held, matching the nano app.
constexpr uint32_t kStepIntervalMs = 160;

uint8_t g_map_raw[kMapBytes];
// One palette index per pixel; the colours live in map.bin's palette. The
// hero's own frames (RW_HERO_FRAMES_BYTES), when the export carries one, sit
// right after the ordinary atlas, then up to kMaxEventFrames more -- see
// rw_open. Both reserved unconditionally, same reasoning: a fixed size beats
// a second/third buffer size to get right.
uint8_t g_tiles[kMaxTiles * RW_TILE_PIXELS + RW_HERO_FRAMES_BYTES +
               kMaxEventFrames * RW_EVENT_FRAME_PIXELS];
// One composited cell, converted to the panel's RGB565 (512 B, so a static
// rather than a stack buffer on a board with this little SRAM).
uint16_t g_cell565[RW_TILE_PIXELS];
uint16_t g_cell1555[RW_TILE_PIXELS];
// The hero's own composited frame, ARGB1555 like g_cell1555 but with a
// transparent pixel staying 0 rather than resolving to the backdrop -- see
// rw_compose_hero -- so draw_hero skips it instead of drawing over it.
uint16_t g_hero1555[RW_HERO_FRAME_PIXELS];
// One event's own composited frame, same convention as g_hero1555.
uint16_t g_event1555[RW_EVENT_FRAME_PIXELS];

TFT_eSPI g_tft;
rw_map g_map;
rw_status g_status = RW_ERR_SHORT_HEADER;
uint32_t g_last_step_ms;

// ARGB1555 (what the export carries) -> BGR565 (what this panel's pushImage
// actually wants -- confirmed on real hardware: packing straight RGB565 came
// out with red and blue swapped on screen, i.e. this board's colour order is
// BGR, not TFT_eSPI's RGB default). The alpha bit is gone by now
// (rw_compose_cell resolves every hole to the backdrop), so only the green
// channel has to grow, its low bit replicated from the high one so a
// full-scale 31 stays full-scale 63.
inline uint16_t to565(uint16_t c) {
  uint16_t r = (c >> 10) & 0x1f;
  uint16_t g = (c >> 5) & 0x1f;
  uint16_t b = c & 0x1f;
  return (uint16_t)((b << 11) | (((g << 1) | (g >> 4)) << 5) | r);
}

// Same, but for TFT_eSPI::pushImage(w, h, uint16_t*) specifically (i.e. the
// per-tile buffer below, not fillScreen/fillCircle/print). Measured on real
// hardware with a primaries test pattern (a pushImage swatch next to a
// fillRect swatch of the same intended colour): pushImage's bulk path
// (TFT_eSPI.cpp's pushColors -> a raw _com.transfer of the buffer, which
// ignores setSwapBytes on this SAMD51 build) does *not* need the BGR field
// swap to565() applies for the scalar path -- feeding it that swap plus a
// byte-swap measured as a clean, full R<->B flip (pure R rendered blue, pure
// B rendered red, G and white untouched), i.e. the two corrections cancelled
// wrongly instead of stacking. Packing plain (unswapped) R5G6B5 and then
// byte-swapping is what actually lands correctly here -- see the swatch
// test in the git history of this file if this ever needs re-deriving.
inline uint16_t to565_push(uint16_t c) {
  const uint16_t r = (c >> 10) & 0x1f;
  const uint16_t g = (c >> 5) & 0x1f;
  const uint16_t b = c & 0x1f;
  const uint16_t v = (uint16_t)((r << 11) | (((g << 1) | (g >> 4)) << 5) | b);
  return (uint16_t)((v << 8) | (v >> 8));
}

// Read a whole file into `buf`, returning the byte count (0 when it is
// missing). A file bigger than the buffer comes back truncated on purpose:
// rw_open turns that into "bigger than this device" rather than a read past
// the end.
uint32_t read_file(const char* path, void* buf, uint32_t cap) {
  File f = SD.open(path, FILE_READ);
  if (!f)
    return 0;
  const size_t n = f.read(buf, cap);
  f.close();
  return (uint32_t)n;
}

void message(const char* line1, const char* line2) {
  g_tft.fillScreen(TFT_BLACK);
  g_tft.setTextColor(TFT_WHITE, TFT_BLACK);
  g_tft.setTextSize(2);
  g_tft.drawString(line1, 8, 8);
  if (line2)
    g_tft.drawString(line2, 8, 32);
}

// The hero sprite, drawn over whatever the cell loop already put down: wider
// and taller than a tile (rw_hero_screen_pos centres and bottom-anchors it
// the same way the genuine renderer does) and, unlike a cell, not every
// pixel is opaque -- a transparent one is skipped rather than drawn, so
// pushImage's unconditional rect copy cannot draw this; it goes through
// drawPixel (the scalar path, hence to565 rather than to565_push) one opaque
// pixel at a time instead. No hero was exported for a project whose initial
// party carries no CharSet (rw_compose_hero fills g_hero1555 with all zeroes
// then), so this simply draws nothing.
void draw_hero(int cam_x, int cam_y, bool moving) {
  rw_compose_hero(&g_map, moving, g_hero1555);
  int px, py;
  rw_hero_screen_pos(&g_map, cam_x, cam_y, &px, &py);

  for (int y = 0; y < RW_HERO_FRAME_H; ++y) {
    const int sy = py + y;
    if (sy < 0 || sy >= g_tft.height())
      continue;
    for (int x = 0; x < RW_HERO_FRAME_W; ++x) {
      const uint16_t c = g_hero1555[y * RW_HERO_FRAME_W + x];
      const int sx = px + x;
      if (c == 0 || sx < 0 || sx >= g_tft.width())
        continue;
      g_tft.drawPixel(sx, sy, to565(c));
    }
  }
}

// One event sprite, the same drawing shape as draw_hero (wider/taller than a
// tile, not every pixel opaque, so a per-pixel skip test rather than
// pushImage's unconditional rect copy) but with no live facing or walk cycle
// to pick between -- rw_compose_event already names the one frame the
// export chose. Always redrawn along with every other event whenever
// draw_map runs at all, moving_only included, for the same reason draw_hero
// is: an animation tick's cell repaint can land on a tile a static event
// sprite is sitting on, and only redrawing the event on top again -- rather
// than skipping it because nothing about the *event* changed -- keeps it
// from being erased.
void draw_event(int index, int cam_x, int cam_y) {
  rw_compose_event(&g_map, index, g_event1555);
  int px, py;
  rw_event_screen_pos(&g_map, index, cam_x, cam_y, &px, &py);

  for (int y = 0; y < RW_EVENT_FRAME_H; ++y) {
    const int sy = py + y;
    if (sy < 0 || sy >= g_tft.height())
      continue;
    for (int x = 0; x < RW_EVENT_FRAME_W; ++x) {
      const uint16_t c = g_event1555[y * RW_EVENT_FRAME_W + x];
      const int sx = px + x;
      if (c == 0 || sx < 0 || sx >= g_tft.width())
        continue;
      g_tft.drawPixel(sx, sy, to565(c));
    }
  }
}

// `moving_only` redraws just the cells the animation clocks moved -- the
// water, typically -- which matters more here than on the nano: a full
// repaint is a whole 320x240 frame over SPI, and an animation tick lands
// several times a second. The hero and every event always redraw on top
// regardless -- an animation tick can repaint a cell either overlaps, and
// the hero's own pose can have changed on a step this same call is already
// handling.
void draw_map(bool moving_only = false, bool moving = false) {
  const int view_w = g_tft.width() / RW_TS;
  const int view_h = g_tft.height() / RW_TS;
  int cam_x, cam_y;
  rw_camera(&g_map, view_w, view_h, &cam_x, &cam_y);

  if (!moving_only)
    g_tft.fillScreen(to565(g_map.backdrop));

  for (int ty = 0; ty < view_h; ++ty) {
    const int my = cam_y + ty;
    if (my >= g_map.height)
      break;
    for (int tx = 0; tx < view_w; ++tx) {
      const int mx = cam_x + tx;
      if (mx >= g_map.width)
        break;
      if (moving_only && !rw_cell_animated(&g_map, mx, my))
        continue;

      rw_compose_cell(&g_map, mx, my, g_cell1555);
      for (int i = 0; i < RW_TILE_PIXELS; ++i)
        g_cell565[i] = to565_push(g_cell1555[i]);

      g_tft.pushImage(tx * RW_TS, ty * RW_TS, RW_TS, RW_TS, g_cell565);
    }
  }

  // Below/same-behind first (under the hero), then the hero, then
  // same-in-front/above (over the hero) -- rw_event_before_hero's own doc
  // comment names the exact rule, matching the genuine renderer's
  // event_target_buffer split. Events export sorted by (y, x)
  // (export_nano7_map.rb), so this loop's own draw order within each half
  // already matches RPG_RT's same-tier y-sort with no on-device work.
  for (int i = 0; i < g_map.event_count; ++i)
    if (rw_event_before_hero(&g_map, i))
      draw_event(i, cam_x, cam_y);
  draw_hero(cam_x, cam_y, moving);
  for (int i = 0; i < g_map.event_count; ++i)
    if (!rw_event_before_hero(&g_map, i))
      draw_event(i, cam_x, cam_y);
}

// The 5-way switch, straight off the board's own pin macros (the same signals
// mruby-rgss/src/wio.cxx binds for the LVGL firmware; this build links neither
// LVGL nor that HAL, so it reads them itself). Pressed reads LOW.
void input_init(void) {
  pinMode(WIO_5S_UP, INPUT_PULLUP);
  pinMode(WIO_5S_DOWN, INPUT_PULLUP);
  pinMode(WIO_5S_LEFT, INPUT_PULLUP);
  pinMode(WIO_5S_RIGHT, INPUT_PULLUP);
}

// RPG2000 counts animation in 60ths of a second, which is what the export's
// clock periods are in; 3/50 is that ratio exactly.
uint32_t rpg_frame(void) {
  return (millis() * 3u) / 50u;
}

void input_direction(int* dx, int* dy) {
  *dx = 0;
  *dy = 0;
  if (digitalRead(WIO_5S_UP) == LOW)
    *dy = -1;
  else if (digitalRead(WIO_5S_DOWN) == LOW)
    *dy = 1;
  else if (digitalRead(WIO_5S_LEFT) == LOW)
    *dx = -1;
  else if (digitalRead(WIO_5S_RIGHT) == LOW)
    *dx = 1;
}

}  // namespace

void setup(void) {
  g_tft.begin();
  g_tft.setRotation(3);
  input_init();

  if (!SD.begin(SDCARD_SS_PIN, SDCARD_SPI)) {
    message("no SD card", "insert the exported map");
    return;
  }

  const uint32_t map_len = read_file(kMapPath, g_map_raw, sizeof(g_map_raw));
  const uint32_t tiles_len = read_file(kTilesPath, g_tiles, sizeof(g_tiles));
  g_status = rw_open(&g_map, g_map_raw, map_len, g_tiles, tiles_len);
  if (g_status != RW_OK) {
    message("no map to walk:", rw_status_str(g_status));
    return;
  }

  g_last_step_ms = millis();
  rw_set_frame(&g_map, rpg_frame());
  draw_map();
}

void loop(void) {
  if (g_status != RW_OK)
    return;

  int dx, dy;
  input_direction(&dx, &dy);
  const bool moving = dx != 0 || dy != 0;

  if (moving) {
    const uint32_t now = millis();
    if (now - g_last_step_ms >= kStepIntervalMs) {
      rw_try_move(&g_map, dx, dy);
      g_last_step_ms = now;
      rw_set_frame(&g_map, rpg_frame());
      draw_map(false, true);
      return;
    }
  } else {
    // Released: the next press steps at once instead of waiting out whatever
    // was left of the interval.
    g_last_step_ms = millis() - kStepIntervalMs;
  }

  // A still map never reaches the redraw: rw_set_frame reports a step only
  // when a clock this map actually uses has moved. Still redraws the hero on
  // its own, held-direction pose -- a bump against a wall keeps the walk
  // cycle alive rather than freezing mid-step.
  if (g_map.animated && rw_set_frame(&g_map, rpg_frame()))
    draw_map(true, moving);
}
