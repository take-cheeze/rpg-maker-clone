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
// Display size is 320x240, not the panel's nominal 320x480: that is the
// largest window the driver was ever observed to address under Renode
// (its own fill covers exactly 320x240 -- see app/maix/README.md), so LVGL
// renders in the driver's own coordinate space. Whether that is the whole
// physical panel (rotation) or a clipped window is a real-hardware
// follow-up; the smoke test asserts the driver-space frame either way.
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
// Raw panel command + area/window primitives for the banded flush below,
// plus the SPI bus helpers shared with the SD layer.
#include <st7789.h>

#include "maix_tf_sd.h"

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

// First-flush LCD bus latch (see maix_tf_sd.h): the SD layer owns the SPI0
// pins from maix_sd_init until the first frame renders; claim them back
// for the panel here, once, then leave them (post-title SD reads need
// full per-op arbitration -- not yet implemented, see the header).
static bool s_lcd_claimed = false;

namespace {

// MUST be SPI0 for the Maix series on-board LCD (per the driver's own
// basic_display example); the LCD pins (CS 36 / RST 37 / DC 38) match the
// driver's defaults, same as app/wio/src/maix_amigo_main.cxx.
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
  if (!s_lcd_claimed) {
    s_lcd_claimed = true;
    maix_spi_take_lcd();
  }
  const uint16_t* src = reinterpret_cast<uint16_t*>(px_map);
  if (((uint32_t)(w * h) & 1u) != 0u) {
    // Odd pixel count: the pair-wise copy below can't cover the tail --
    // fall back to the driver's own (Renode-proven) helper.
    g_lcd.drawImage(static_cast<uint16_t>(area->x1),
                    static_cast<uint16_t>(area->y1), static_cast<uint16_t>(w),
                    static_cast<uint16_t>(h),
                    reinterpret_cast<uint16_t*>(px_map));
    lv_display_flush_ready(disp);
    return;
  }
  for (int q = 0; q < MAIX_FLUSH_QUARTERS; ++q) {
    const int32_t y0 = (h * q) / MAIX_FLUSH_QUARTERS;
    const int32_t y1 = (h * (q + 1)) / MAIX_FLUSH_QUARTERS;
    const int32_t rows = y1 - y0;
    for (int32_t i = 0; i < w * rows; i += 2) {
      const uint32_t s = (uint32_t)(y0 * w) + (uint32_t)i;
      s_flush_band[i] = MAIX_SWAP_16(src[s + 1]);
      s_flush_band[i + 1] = MAIX_SWAP_16(src[s]);
    }
    lcd_set_area((uint16_t)(area->x1), (uint16_t)(area->y1 + y0),
                 (uint16_t)(area->x1 + w - 1), (uint16_t)(area->y1 + y1 - 1));
    tft_write_half(s_flush_band, (uint32_t)(w * rows));
    usleep(5000);
  }
  lcd_set_direction(DIR_YX_LRDU);
  tft_write_command(INVERSION_DISPALY_OFF);
  lv_display_flush_ready(disp);
}

}  // namespace

// Visible to the boot smoke's diagnostics (maix_rgss_boot_main.cxx reads
// back the first rendered word to tell a render problem from a flush
// problem while this HAL is being brought up). Declared in maix.hxx.
uint16_t* g_maix_framebuffer = nullptr;

lv_display_t* maix_display_create(int32_t hor_res, int32_t ver_res) {
  g_lcd.begin();
  // Un-mirror: begin() installs DIR_YX_RLDU (MADCTL 0xA0), which renders
  // mirrored left-right on this panel (confirmed on hardware). DIR_YX_LRDU
  // (0xE0) keeps MY/MV -- same orientation and dimensions -- and flips only
  // the column order bit MX. Verified against the real Amigo TFT; revisit
  // if a panel revision shows otherwise.
  // Inversion off to match: this panel variant powers up BGR + inverted
  // relative to the driver's assumes (white paints read back black,
  // blue reads back cyan on hardware); the E0 + INVOFF combination is the
  // one window of the hardware color probe that showed true colors.
  lcd_set_direction(DIR_YX_LRDU);
  tft_write_command(INVERSION_DISPALY_OFF);
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
