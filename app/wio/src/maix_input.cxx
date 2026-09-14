// Maix Amigo input: capacitive touch + RGSS bridge (PlatformIO side).
//
// The scan half reads the panel's FT6X36 capacitive touch controller over
// I2C1 (Wire1, the variant's own SCL/SDA pins) into a bitmask; the bridge
// half diffs it against the previous frame and drives RGSS::Input.press /
// .release on the edges, mirroring input_bridge.cxx for SDL. A tap is
// Confirm -- the only binding a board with no d-pad can offer yet;
// directions (touch regions) belong to the menu work that needs them (see
// app/maix/README.md).
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

#include <Arduino.h>
#include <Wire.h>

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/value.h>

namespace {

// FocalTech FT6X36 register set (I2C address 0x38): touch count at 0x02,
// first point's X/Y in the four bytes after it.
constexpr uint8_t kTouchAddr = 0x38;
constexpr uint8_t kRegTouches = 0x02;

bool touch_present(void) {
  Wire1.beginTransmission(kTouchAddr);
  Wire1.write(kRegTouches);
  if (Wire1.endTransmission(false) != 0)
    return false;
  if (Wire1.requestFrom(kTouchAddr, static_cast<uint8_t>(5)) < 5)
    return false;
  const int count = Wire1.read();
  // Drain the first point's X/Y (positions become touch regions when the
  // menu work needs them; the count alone answers Confirm for now).
  Wire1.read();
  Wire1.read();
  Wire1.read();
  Wire1.read();
  return count > 0;
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
  return touch_present() ? (1u << MAIX_INPUT_C) : 0;
}

extern "C" void rgss_maix_poll(mrb_state* M) {
  const uint64_t cur = maix_input_scan();
  const uint64_t changed = cur ^ g_prev;
  if (changed) {
    for (int key = 0; key < MAIX_INPUT_KEY_COUNT; ++key) {
      const uint64_t bit = 1ull << key;
      if (changed & bit)
        send_key(M, key, (cur & bit) != 0);
    }
    g_prev = cur;
  }
}
