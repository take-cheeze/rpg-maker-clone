// M5Stack Core (ESP32) LVGL display + input HAL. See include/m5stack.hxx for
// the contract and why this file is a no-op unless M5STACK_CORE is defined.

#ifdef M5STACK_CORE

#include "m5stack.hxx"

#include <Arduino.h>
#include <TFT_eSPI.h>  // configured for the Core's ILI9341 via build_flags

namespace {

// The board's LCD driver. Pins/driver are supplied entirely through
// build_flags (-DUSER_SETUP_LOADED=1 and friends -- see
// app/m5stack/README.md), not a checked-in User_Setup.h, so this same
// TFT_eSPI works for any M5Stack Core variant wired the standard way.
TFT_eSPI g_tft;

// LVGL partial-render draw buffers, the same shape and sizing rationale as
// wio.cxx's: ten rows of RGB565 across the 320-wide panel is 320*10*2 =
// 6.4 KB each, two buffers so a bulk SPI flush of one can overlap rendering
// into the other.
constexpr int32_t kPanelWidth = 320;
constexpr int32_t kBufRows = 10;
uint8_t g_buf1[kPanelWidth * kBufRows * 2];
uint8_t g_buf2[kPanelWidth * kBufRows * 2];

uint32_t tick_cb(void) {
  return static_cast<uint32_t>(millis());
}

void delay_cb(uint32_t ms) {
  delay(ms);
}

// Push one rendered rectangle to the LCD. LVGL hands RGB565 pixels; the panel
// expects byte-swapped RGB565, so setSwapBytes(true) is set once at init.
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

// M5Stack Core's three front buttons. GPIO 34-39 are ESP32 input-only pins
// with no internal pull resistor; the board itself pulls each line high, so
// these are read with a plain INPUT (see m5stack_input_init below), active
// low, same polarity as every other board this project reads buttons on.
struct PinMap {
  uint8_t pin;
  uint8_t key;
};

constexpr uint8_t kButtonAPin = 39;
constexpr uint8_t kButtonBPin = 38;
constexpr uint8_t kButtonCPin = 37;

const PinMap kPins[] = {
    {kButtonAPin, M5_INPUT_A},
    {kButtonBPin, M5_INPUT_B},
    {kButtonCPin, M5_INPUT_C},
};

}  // namespace

lv_display_t* m5stack_display_create(int32_t hor_res, int32_t ver_res) {
  g_tft.begin();
  // Rotation 1: landscape, buttons/USB-C at the bottom -- the Core's usual
  // hand-held orientation.
  g_tft.setRotation(1);
  g_tft.setSwapBytes(true);
  g_tft.fillScreen(TFT_BLACK);

  lv_tick_set_cb(tick_cb);
  lv_delay_set_cb(delay_cb);

  lv_display_t* disp = lv_display_create(hor_res, ver_res);
  if (!disp)
    return nullptr;

  lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
  lv_display_set_buffers(disp, g_buf1, g_buf2, sizeof(g_buf1),
                         LV_DISPLAY_RENDER_MODE_PARTIAL);
  lv_display_set_flush_cb(disp, flush_cb);
  return disp;
}

void m5stack_input_init(void) {
  for (const PinMap& p : kPins)
    pinMode(p.pin, INPUT);
}

uint64_t m5stack_input_scan(void) {
  uint64_t mask = 0;
  for (const PinMap& p : kPins) {
    if (digitalRead(p.pin) == LOW)  // active low
      mask |= (1ull << p.key);
  }
  return mask;
}

#endif  // M5STACK_CORE
