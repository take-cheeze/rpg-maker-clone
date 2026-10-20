// Maix Amigo display HAL (PlatformIO side).
//
// Stands up an LVGL display over the board's TFT through Maixduino's
// Sipeed_ST7789 driver (SPI0): a full-frame RGB565 buffer from the newlib
// heap, flushed per dirty rectangle with the driver's own drawImage.
// Unlike the Wio Terminal's partial buffers (forced by 192 KB SRAM), a full
// 320x240 frame is 150 KB -- affordable on this board's 8 MB SRAM and much
// simpler to reason about. Also installs the millis()/delay() tick+delay
// source LVGL needs without SDL.
//
// RGSS::Graphics.width/height (and every game's own coordinate math) come
// straight from the LVGL display's resolution, so it stays RPG2k's real
// native 320x240 -- matching the PSP port's own documented rule (app/psp/
// main.cxx's file comment): making it bigger to fill more of the panel
// would silently distort every game's own on-screen layout, not just show
// more of it. What DOES need to match the real panel is where that 320x240
// canvas lands: confirmed on real hardware (not just under Renode, which
// only ever proved the raw byte stream, never on-panel placement) that an
// un-offset flush draws into the panel's top-left corner, small relative
// to its real (3.5", nominal 320x480 portrait) size -- so flush_cb below
// centers the canvas inside the panel's post-rotation landscape extent
// (480x320, portrait transposed by the display direction's MV bit) instead of
// anchoring at (0,0), and maix_display_create clears the whole panel once
// so the letterboxed margin is black, not whatever was left over from
// before this firmware ran. The exact 480x320 figure is inferred from the
// portrait spec plus the rotation, not independently measured -- if the
// margins look wrong (cut off on one edge, too much on another), that is
// the exact place to correct.
//
// Deliberately PIO-side (not in libmruby.a): needs Arduino/SPI/LCD headers
// that the rake cross-build never sees, and the firmware links LVGL itself,
// so nothing here pays the RGSS_WIO_ARDUINO_INCLUDES price the wio.cxx HAL
// does. The mruby side needs no counterpart: lib.cxx already reaches the
// injected display through rgss_set_display.

#include "maix.hxx"

#include <cstdlib>

#include <Arduino.h>
#include <SPI.h>
#include <Sipeed_ST7789.h>

// lcd_set_direction (the driver's C core, lcd.h, extern "C" itself) to
// override the direction begin() installs -- see maix_display_create.
#include <lcd.h>
// Raw panel command + area/window primitives for the banded flush below.
#include <st7789.h>

// Byte-swap a pixel for the panel's big-endian 16-bit frames (same as the
// driver's own lcd_draw_picture does per pixel).
#define MAIX_SWAP_16(x) \
  ((uint16_t)(((uint16_t)(x) >> 8 & 0xff) | ((uint16_t)(x) << 8)))

// Flush in four quarter-frame bands, each a single area-setup plus one
// data DMA mirroring the hardware probe's band shape that lands uniformly
// on real silicon: single medium writes land, while one giant 38400-word
// DMA truncates and many back-to-back small DMAs alternate-drop. Pair-wise
// pixel order matches the driver's own copy loop exactly.
#define MAIX_FLUSH_QUARTERS 4

// Scratch for one quarter band max (320x60 px RGB565).
static uint16_t s_flush_band[320 * 60];

// The panel's real landscape extent (post-rotation) and the offset that
// centers RPG2k's fixed 320x240 canvas inside it -- see the file header
// comment above for where these numbers come from and their confidence
// level.
constexpr int32_t kPanelW = 480;
constexpr int32_t kPanelH = 320;
constexpr int32_t kOffsetX = (kPanelW - 320) / 2;
constexpr int32_t kOffsetY = (kPanelH - 240) / 2;

namespace {

// MUST be SPI0 for the Maix series on-board LCD (per the driver's own
// basic_display example); the LCD pins (CS 36 / RST 37 / DC 38) match the
// driver's defaults, same as app/wio/src/maix_amigo_main.cxx. The TF card
// (maix_tf_sd.h) is on the independent SPI1, per the official schematic --
// no bus sharing with the LCD to arbitrate.
SPIClass g_spi(SPI0);
Sipeed_ST7789 g_lcd(320, 480, g_spi);

uint32_t tick_cb(void) {
  return millis();
}

void delay_cb(uint32_t ms) {
  delay(ms);
}

void flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
  const int32_t w = area->x2 - area->x1 + 1;
  const int32_t h = area->y2 - area->y1 + 1;
  const uint16_t* src = reinterpret_cast<uint16_t*>(px_map);
  if (((uint32_t)(w * h) & 1u) != 0u) {
    // Odd pixel count: the pair-wise copy below can't cover the tail --
    // fall back to the driver's own (Renode-proven) helper.
    g_lcd.drawImage(static_cast<uint16_t>(area->x1 + kOffsetX),
                    static_cast<uint16_t>(area->y1 + kOffsetY),
                    static_cast<uint16_t>(w), static_cast<uint16_t>(h),
                    reinterpret_cast<uint16_t*>(px_map));
    lv_display_flush_ready(disp);
    return;
  }
  for (int q = 0; q < MAIX_FLUSH_QUARTERS; ++q) {
    const int32_t y0 = (h * q) / MAIX_FLUSH_QUARTERS;
    const int32_t y1 = (h * (q + 1)) / MAIX_FLUSH_QUARTERS;
    const int32_t rows = y1 - y0;
    // Pair-wise pixel order, matching the driver's own lcd_draw_picture()
    // (Sipeed_ST7789/lcd.c) exactly -- its g_lcd_display_buff[i] =
    // SWAP_16(*(p+1)); g_lcd_display_buff[i+1] = SWAP_16(*(p)); is the same
    // shape. That function pairs this with tft_write_word (32-bit,
    // SPI_TRANS_INT), which is why this does too: tft_write_half (16-bit,
    // SPI_TRANS_SHORT) mallocs a fresh widening buffer on *every single
    // call* with no null-check (framework-maixduino's spi.c,
    // spi_send_data_normal_dma) -- confirmed on real hardware to crash hard
    // (a fault store through the null pointer malloc returned) once enough
    // flushes have run to exhaust/fragment the heap, reproduced twice with
    // an identical crash address. tft_write_word takes the buffer directly,
    // no allocation at all.
    for (int32_t i = 0; i < w * rows; i += 2) {
      const uint32_t s = (uint32_t)(y0 * w) + (uint32_t)i;
      s_flush_band[i] = MAIX_SWAP_16(src[s + 1]);
      s_flush_band[i + 1] = MAIX_SWAP_16(src[s]);
    }
    lcd_set_area((uint16_t)(area->x1 + kOffsetX),
                 (uint16_t)(area->y1 + y0 + kOffsetY),
                 (uint16_t)(area->x1 + w - 1 + kOffsetX),
                 (uint16_t)(area->y1 + y1 - 1 + kOffsetY));
    tft_write_word(reinterpret_cast<uint32_t*>(s_flush_band),
                   (uint32_t)(w * rows) / 2);
    usleep(5000);
  }
  lcd_set_direction(DIR_YX_RLUD);
  tft_write_command(INVERSION_DISPALY_ON);
  lv_display_flush_ready(disp);
}

// Fills the whole physical panel with one RGB565 color, already in wire
// byte order (MAIX_SWAP_16'd, matching what flush_cb sends for real
// content). Reuses s_flush_band -- sized for a 320x60 band, i.e. exactly
// 40 full-width (kPanelW) rows, so kPanelH/40 chunks cover it exactly.
// tft_write_word, not tft_write_half -- see flush_cb's own comment on why
// (a malloc with no null-check on every tft_write_half call). Every pixel
// here is the same value, so pairing two into one 32-bit word needs no
// swap: both halves are identical either way.
void fill_panel(uint16_t wire_color) {
  constexpr int32_t kRowsPerChunk =
      static_cast<int32_t>(sizeof(s_flush_band) / sizeof(s_flush_band[0])) /
      kPanelW;
  static_assert(kPanelH % kRowsPerChunk == 0,
                "fill_panel chunk size must divide kPanelH evenly");
  for (int i = 0; i < kPanelW * kRowsPerChunk; ++i)
    s_flush_band[i] = wire_color;
  for (int32_t y = 0; y < kPanelH; y += kRowsPerChunk) {
    lcd_set_area(0, static_cast<uint16_t>(y),
                 static_cast<uint16_t>(kPanelW - 1),
                 static_cast<uint16_t>(y + kRowsPerChunk - 1));
    tft_write_word(reinterpret_cast<uint32_t*>(s_flush_band),
                   static_cast<uint32_t>(kPanelW * kRowsPerChunk) / 2);
  }
}

// Clears the whole physical panel black, once, before LVGL ever draws
// anything: RPG2k's canvas only covers the centered kOffsetX/kOffsetY
// region of it (see the file header comment), so without this the margin
// shows whatever was left over from a previous firmware run or the
// panel's own power-on state instead of a clean letterbox.
void clear_panel(void) {
  fill_panel(0);
}

}  // namespace

// Blits a small RGB565 buffer (native order -- this swaps each pixel
// itself, same as flush_cb) directly to panel coordinates
// (x,y)-(x+w-1,y+h-1), bypassing LVGL entirely. For content living outside
// the LVGL canvas's own kOffsetX/kOffsetY window -- the gamepad overlay,
// drawn in the panel's margins so it never covers the game's own screen
// (see maix_gamepad.cxx) -- LVGL has no notion that space exists at all.
// w*h must fit in one s_flush_band-sized chunk (320*60 = 19200 px); every
// caller today is a single D-pad cell or button, at most ~3,700 px, so
// this clips (rather than corrupts memory) instead of chunking a case
// that has never actually come up. Declared in maix.hxx.
//
// tft_write_word, not tft_write_half -- see flush_cb's own comment on why
// (a malloc with no null-check on every tft_write_half call). Pairs two
// pixels per 32-bit word, same pair-wise order as lcd_draw_picture's own
// reference implementation. w*h is odd for every caller today (a 25x25
// D-pad cell, a (2r+1)x(2r+1) circle bounding box) -- rather than resize
// every shape to force an even count, the trailing pixel is just dropped:
// it is always the buffer's last element, the bottom-right corner of an
// outline shape's bounding box, which every caller here leaves as
// background (never actually drawn on), so there is nothing to lose.
void maix_panel_blit(int32_t x,
                     int32_t y,
                     int32_t w,
                     int32_t h,
                     const uint16_t* pixels) {
  const int32_t count = w * h;
  constexpr int32_t kMaxCount =
      static_cast<int32_t>(sizeof(s_flush_band) / sizeof(s_flush_band[0]));
  if (count <= 0 || count > kMaxCount)
    return;
  const int32_t pairs = count / 2;
  for (int32_t i = 0; i < pairs; ++i) {
    s_flush_band[2 * i] = MAIX_SWAP_16(pixels[2 * i + 1]);
    s_flush_band[2 * i + 1] = MAIX_SWAP_16(pixels[2 * i]);
  }
  if (pairs == 0)
    return;
  lcd_set_area(static_cast<uint16_t>(x), static_cast<uint16_t>(y),
               static_cast<uint16_t>(x + w - 1),
               static_cast<uint16_t>(y + h - 1));
  tft_write_word(reinterpret_cast<uint32_t*>(s_flush_band),
                 static_cast<uint32_t>(pairs));
}

// Visible to the boot smoke's diagnostics (maix_rgss_boot_main.cxx reads
// back the first rendered word to tell a render problem from a flush
// problem while this HAL is being brought up). Declared in maix.hxx.
uint16_t* g_maix_framebuffer = nullptr;

lv_display_t* maix_display_create(int32_t hor_res, int32_t ver_res) {
  g_lcd.begin();
  // DIR_YX_RLUD (MADCTL 0x20: MY=0, MX=0, MV=1 -- transpose for landscape,
  // neither axis mirrored): confirmed on real hardware with a photo of the
  // actual title screen. begin()'s own default (DIR_YX_RLDU, MY=1) was
  // separately confirmed left-right mirrored on this panel by an earlier,
  // simpler test (P0's own boot-time text, drawn through the driver's high-
  // level helpers, a different code path from this file's banded flush +
  // panel-centering); that earlier test's own fix, DIR_YX_LRDU (only MX
  // flipped from the default), turned out to still be 180 off *on this
  // code path* -- readable only if the whole photographed screen is
  // rotated upside-down, both axes wrong, not just one -- found by cycling
  // all four DIR_YX_* directions on an already-rendered frame and
  // photographing each. Revisit if a panel revision shows otherwise.
  // INVERSION_DISPALY_ON, not OFF: confirmed on real hardware with a
  // labeled full-palette probe (black/white/gray50/red/green/blue/teal, in
  // turn, under each setting back to back) that ON is the one where every
  // color reads correctly -- most tellingly gray50 (a 50% RGB565 gray,
  // R=16/G=32/B=16) actually looks gray under ON, where OFF collapsed it
  // (and the game's own teal background) toward black. An earlier revision
  // had this backwards (OFF), from a probe that only ever checked a few
  // colors, none of them a midtone.
  lcd_set_direction(DIR_YX_RLUD);
  tft_write_command(INVERSION_DISPALY_ON);
  clear_panel();
  lv_tick_set_cb(tick_cb);
  lv_delay_set_cb(delay_cb);

  lv_display_t* disp = lv_display_create(hor_res, ver_res);
  if (!disp)
    return nullptr;
  lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);

  const size_t px_count =
      static_cast<size_t>(hor_res) * static_cast<size_t>(ver_res);
  uint8_t* buf =
      static_cast<uint8_t*>(std::malloc(px_count * sizeof(uint16_t)));
  if (!buf)
    return nullptr;
  g_maix_framebuffer = reinterpret_cast<uint16_t*>(buf);
  lv_display_set_buffers(disp, buf, nullptr, px_count * sizeof(uint16_t),
                         LV_DISPLAY_RENDER_MODE_FULL);
  lv_display_set_flush_cb(disp, flush_cb);
  return disp;
}
