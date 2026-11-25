// Wio Terminal (Seeed, ATSAMD51) LVGL display + input HAL. See include/wio.hxx
// for the contract and why this file is a no-op unless WIO_TERMINAL is defined.

#ifdef WIO_TERMINAL

#include "wio.hxx"

#include <Arduino.h>
#include <TFT_eSPI.h>  // from Seeed_Arduino_LCD (a TFT_eSPI fork)
#include <mruby.h>

namespace {

// The board's LCD driver (a TFT_eSPI fork preconfigured for the Wio Terminal's
// pins in the Seeed board package).
TFT_eSPI g_tft;

// The LVGL partial-render draw buffer: ten rows of RGB565 across the 320-wide
// panel, 6.4 KB (a full 320x240x2 framebuffer would take 150 KB of the 192 KB
// SRAM). One buffer is enough: flush_cb returns only once the transfer is done,
// so a second buffer could never be rendered into while the first one flushes.
constexpr int32_t kPanelWidth = 320;
constexpr int32_t kBufRows = 10;
uint8_t g_buf[kPanelWidth * kBufRows * 2];

// LVGL needs a tick and a delay source without SDL. Arduino's millis()/delay()
// provide both; wrap them so the function-pointer types match exactly (millis()
// returns unsigned long, lv_tick_set_cb wants uint32_t (*)(void)).
uint32_t tick_cb(void) {
  return static_cast<uint32_t>(millis());
}

void delay_cb(uint32_t ms) {
  delay(ms);
}

// Push one rendered rectangle to the LCD. LVGL hands RGB565 pixels; the panel
// expects byte-swapped RGB565, so setSwapBytes(true) is set once at init.
// pushColors blocks until the SPI transfer has finished (SPIClass::transfer
// with block = true), so the buffer is free again when flush_ready is called.
void flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
  const int32_t w = lv_area_get_width(area);
  const int32_t h = lv_area_get_height(area);

  g_tft.startWrite();
  g_tft.setAddrWindow(area->x1, area->y1, w, h);
  g_tft.pushColors(reinterpret_cast<uint16_t*>(px_map),
                   static_cast<uint32_t>(w) * h, true);
  g_tft.endWrite();

  lv_display_flush_ready(disp);
}

// The three top buttons and the 5-way switch, mapped to RGSS key ids. The board
// package defines these pin macros. Buttons are active low with a pull-up.
//
// Layout choice: the 5-way switch drives the D-pad and its centre press
// confirms; the three top buttons (physically C, B, A from left to right) map
// to A-button / cancel / confirm, matching the desktop Z/X/C = confirm/cancel/A
// convention so the same games play the same way.
struct PinMap {
  uint8_t pin;
  uint8_t key;
};

const PinMap kPins[] = {
    {WIO_5S_UP, WIO_INPUT_UP},     {WIO_5S_DOWN, WIO_INPUT_DOWN},
    {WIO_5S_LEFT, WIO_INPUT_LEFT}, {WIO_5S_RIGHT, WIO_INPUT_RIGHT},
    {WIO_5S_PRESS, WIO_INPUT_C},   {WIO_KEY_A, WIO_INPUT_C},
    {WIO_KEY_B, WIO_INPUT_B},      {WIO_KEY_C, WIO_INPUT_A},
};

}  // namespace

lv_display_t* wio_display_create(int32_t hor_res, int32_t ver_res) {
  g_tft.begin();
  g_tft.setRotation(3);  // landscape, USB-C on the right
  g_tft.setSwapBytes(true);
  g_tft.fillScreen(TFT_BLACK);

  lv_tick_set_cb(tick_cb);
  lv_delay_set_cb(delay_cb);

  lv_display_t* disp = lv_display_create(hor_res, ver_res);
  if (!disp)
    return nullptr;

  lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
  lv_display_set_buffers(disp, g_buf, nullptr, sizeof(g_buf),
                         LV_DISPLAY_RENDER_MODE_PARTIAL);
  lv_display_set_flush_cb(disp, flush_cb);
  return disp;
}

void wio_input_init(void) {
  for (const PinMap& p : kPins)
    pinMode(p.pin, INPUT_PULLUP);
}

uint64_t wio_input_scan(void) {
  uint64_t mask = 0;
  for (const PinMap& p : kPins) {
    if (digitalRead(p.pin) == LOW)  // active low
      mask |= (1ull << p.key);
  }
  return mask;
}

#ifdef MRB_USE_CUSTOM_RO_DATA_P
// Internal flash (0x0) and the QSPI XIP window (0x04000000) sit below SRAM
// (0x20000000), and nothing writes them while mruby runs.
extern "C" mrb_bool mrb_ro_data_p(const char* p) {
  return reinterpret_cast<uintptr_t>(p) < 0x20000000u;
}
#endif

#endif  // WIO_TERMINAL
