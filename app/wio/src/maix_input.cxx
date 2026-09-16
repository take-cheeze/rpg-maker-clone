// Maix Amigo input: capacitive touch + RGSS bridge (PlatformIO side).
//
// The scan half reads the panel's FT6X36 capacitive touch controller over
// I2C1 (Wire1, the variant's own SCL/SDA pins) into a bitmask; the bridge
// half diffs it against the previous frame and drives RGSS::Input.press /
// .release on the edges, mirroring input_bridge.cxx for SDL. A touch hits
// one of maix_gamepad_layout.h's six regions (the virtual D-pad + Confirm/
// Cancel buttons maix_gamepad.cxx draws) or nothing.
//
// The FT6X36 protocol below is the standard FocalTech register set (device
// 0x38: touch count at 0x02, first point's X/Y at 0x03-0x06) with no vendor
// library -- Maixduino ships none for this chip, and five registers are all
// this scan needs. Best-effort until real hardware: with no panel attached
// (Renode included) every read returns zero, which is exactly the idle
// "no touch" state, so this degrades to a no-op rather than hanging.
//
// Deliberately PIO-side (not in libmruby.a): needs Arduino/Wire headers
// that the rake cross-build never sees. lib.cxx calls rgss_maix_poll from
// input_poll under MAIX_BUILD; firmwares without a game loop (the current
// boot smoke) call it directly instead.

#include "maix.hxx"
#include "maix_gamepad_layout.h"

#include <Arduino.h>
#include <Wire.h>

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/value.h>

namespace {

// FocalTech FT6X36 register set (I2C address 0x38): touch count at 0x02,
// first point's X/Y in the four bytes after it (XH/XL/YH/YL, 12 bits each,
// the high nibble of *H holding bits 11:8).
constexpr uint8_t kTouchAddr = 0x38;
constexpr uint8_t kRegTouches = 0x02;

// Last raw (pre-transform) touch, for the calibration print in
// rgss_maix_poll below -- there is no camera on this hardware, so that
// print is the only way to tell whether maix_gamepad_layout.h's
// TouchToScreen transform (explicitly flagged there as unverified) is
// actually right without eyes on the real panel.
int16_t g_last_raw_x = 0;
int16_t g_last_raw_y = 0;

// Reads the first touch point, if any. Returns false (leaving *sx/*sy
// untouched) when nothing is touched; true with *sx/*sy already converted
// to LVGL screen space (maix_gamepad_layout.h::TouchToScreen) otherwise.
bool touch_scan(int16_t* sx, int16_t* sy) {
  Wire1.beginTransmission(kTouchAddr);
  Wire1.write(kRegTouches);
  if (Wire1.endTransmission(false) != 0)
    return false;
  if (Wire1.requestFrom(kTouchAddr, static_cast<uint8_t>(5)) < 5)
    return false;
  const int count = Wire1.read();
  const int xh = Wire1.read();
  const int xl = Wire1.read();
  const int yh = Wire1.read();
  const int yl = Wire1.read();
  if (count <= 0)
    return false;
  const int16_t tx = static_cast<int16_t>(((xh & 0x0F) << 8) | xl);
  const int16_t ty = static_cast<int16_t>(((yh & 0x0F) << 8) | yl);
  g_last_raw_x = tx;
  g_last_raw_y = ty;
  maix_gamepad::TouchToScreen(tx, ty, sx, sy);
  return true;
}

const char* key_name(int key) {
  switch (key) {
    case MAIX_INPUT_UP:
      return "UP";
    case MAIX_INPUT_DOWN:
      return "DOWN";
    case MAIX_INPUT_LEFT:
      return "LEFT";
    case MAIX_INPUT_RIGHT:
      return "RIGHT";
    case MAIX_INPUT_A:
      return "A";
    case MAIX_INPUT_B:
      return "B";
    case MAIX_INPUT_C:
      return "C";
    default:
      return "?";
  }
}

// Touch state applied to RGSS::Input on the previous poll, so only
// transitions are forwarded.
uint64_t g_prev = 0;

void send_key(mrb_state* M, int key, bool press) {
  RClass* rgss = mrb_module_get(M, "RGSS");
  if (!rgss)
    return;
  RClass* input = mrb_module_get_under(M, rgss, "Input");
  if (!input)
    return;
  mrb_funcall(M, mrb_obj_value(input), press ? "press" : "release", 1,
              mrb_fixnum_value(key));
}

}  // namespace

void maix_input_init(void) {
  Wire1.begin();
}

uint32_t maix_input_scan(void) {
  int16_t x, y;
  if (!touch_scan(&x, &y))
    return 0;
  using namespace maix_gamepad;
  if (InRect(x, y, kUp))
    return 1u << MAIX_INPUT_UP;
  if (InRect(x, y, kDown))
    return 1u << MAIX_INPUT_DOWN;
  if (InRect(x, y, kLeft))
    return 1u << MAIX_INPUT_LEFT;
  if (InRect(x, y, kRight))
    return 1u << MAIX_INPUT_RIGHT;
  if (InCircle(x, y, kConfirm))
    return 1u << MAIX_INPUT_C;
  if (InCircle(x, y, kCancel))
    return 1u << MAIX_INPUT_B;
  return 0;  // touched, but outside every gamepad region
}

extern "C" void rgss_maix_poll(mrb_state* M) {
  const uint64_t cur = maix_input_scan();
  const uint64_t changed = cur ^ g_prev;
  if (changed) {
    for (int key = 0; key < MAIX_INPUT_KEY_COUNT; ++key) {
      const uint64_t bit = 1ull << key;
      if (changed & bit) {
        const bool press = (cur & bit) != 0;
        send_key(M, key, press);
        // Calibration aid (see g_last_raw_x/y's own comment): only prints
        // on press, not release, so a single tap is one line, not two.
        if (press) {
          Serial.print("maix-gamepad: touch raw=(");
          Serial.print(g_last_raw_x);
          Serial.print(",");
          Serial.print(g_last_raw_y);
          Serial.print(") -> ");
          Serial.println(key_name(key));
        }
      }
    }
    g_prev = cur;
  }
}
