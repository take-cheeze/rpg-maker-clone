// Wio Terminal (Seeed, ATSAMD51) display + input HAL. See include/wio.hxx
// for the contract and why this file is a no-op unless WIO_TERMINAL is defined.

#ifdef WIO_TERMINAL

#include "wio.hxx"

#include <Arduino.h>
#include <TFT_eSPI.h>  // from Seeed_Arduino_LCD (a TFT_eSPI fork)
#include <mruby.h>

#ifdef RGSS_GFX_OWN
#include "rgss_gfx_own.hxx"
#else
#include <lvgl.h>
extern "C" void rgss_set_display(mrb_state* M, lv_display_t* display);
#endif

namespace {

// The board's LCD driver (a TFT_eSPI fork preconfigured for the Wio Terminal's
// pins in the Seeed board package).
TFT_eSPI g_tft;

// The draw strip: ten rows of RGB565 across the 320-wide panel, 6.4 KB (a full
// 320x240x2 framebuffer would take 150 KB of the 192 KB SRAM). One is enough:
// a flush returns only once the transfer is done, so a second strip could never
// be drawn into while the first one is pushed.
constexpr int32_t kPanelWidth = 320;
constexpr int32_t kBufRows = 10;
uint16_t g_buf[kPanelWidth * kBufRows];

// What the backends' refresh timer waits between two draws (LVGL's
// LV_DEF_REFR_PERIOD).
constexpr uint32_t kRefreshMs = 33;

WioFlushHook g_hook = nullptr;

uint32_t tick_cb(void) {
  return static_cast<uint32_t>(millis());
}

void delay_cb(uint32_t ms) {
  delay(ms);
}

// The panel expects byte-swapped RGB565, so setSwapBytes(true) is set once at
// init. pushColors blocks until the SPI transfer has finished (SPIClass::
// transfer with block = true), so the strip is free again when it returns.
void push(int32_t x, int32_t y, int32_t w, int32_t h, const uint16_t* px) {
  if (g_hook) {
    g_hook(x, y, w, h, px);
    return;
  }
  g_tft.startWrite();
  g_tft.setAddrWindow(x, y, w, h);
  g_tft.pushColors(const_cast<uint16_t*>(px), static_cast<uint32_t>(w) * h,
                   true);
  g_tft.endWrite();
}

#ifdef RGSS_GFX_OWN
RgssOwnDisplay* g_disp = nullptr;

RgssOwnDisplay* create_display(int32_t hor_res, int32_t ver_res) {
  RgssOwnConfig c{};
  c.width = hor_res;
  c.height = ver_res;
  c.strip = g_buf;
  c.strip_px = sizeof(g_buf) / sizeof(g_buf[0]);
  c.flush = push;
  c.tick_ms = tick_cb;
  c.delay_ms = delay_cb;
  c.refresh_period_ms = kRefreshMs;
  return rgss_own_display_create(&c);
}

void draw_every_frame() {
  rgss_own_set_refresh_period(g_disp, 0);
}
#else
lv_display_t* g_disp = nullptr;

void flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
  push(area->x1, area->y1, lv_area_get_width(area), lv_area_get_height(area),
       reinterpret_cast<const uint16_t*>(px_map));
  lv_display_flush_ready(disp);
}

lv_display_t* create_display(int32_t hor_res, int32_t ver_res) {
  lv_init();
  // millis() returns unsigned long; lv_tick_set_cb wants uint32_t (*)(void).
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

void draw_every_frame() {
  lv_timer_set_period(lv_display_get_refr_timer(g_disp), 0);
}
#endif

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

bool wio_display_begin(int32_t hor_res, int32_t ver_res) {
  g_tft.begin();
  g_tft.setRotation(3);  // landscape, USB-C on the right
  g_tft.setSwapBytes(true);
  g_tft.fillScreen(TFT_BLACK);
  g_disp = create_display(hor_res, ver_res);
  return g_disp != nullptr;
}

void wio_display_attach(mrb_state* M) {
  rgss_set_display(M, g_disp);
}

void wio_display_set_flush_hook(WioFlushHook hook) {
  g_hook = hook;
}

void wio_display_draw_every_frame(void) {
  if (g_disp)
    draw_every_frame();
}

void wio_display_text(int32_t x,
                      int32_t y,
                      uint16_t rgb565,
                      int32_t pad,
                      const char* text) {
  g_tft.setTextColor(rgb565, TFT_BLACK);
  g_tft.setTextDatum(TC_DATUM);
  g_tft.setTextPadding(pad);
  g_tft.drawString(text, x, y, 1);
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
