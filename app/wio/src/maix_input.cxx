// Maix Amigo input: capacitive touch + RGSS bridge (PlatformIO side).
//
// The scan half reads the panel's FT6X36 capacitive touch controller over
// I2C1 (Wire1) into a bitmask, hitting one of maix_gamepad_layout.h's six
// regions (the virtual D-pad + Confirm/Cancel buttons maix_gamepad.cxx
// draws) or nothing; the bridge half diffs it against the previous frame
// and drives RGSS::Input.press/.release on the edges, mirroring
// input_bridge.cxx for SDL.
//
// The case's D-pad/A/B/X/Y/Select/Start art is Sipeed's plug-in Gamepad
// module (GD32F150G, I2C1 at 0x4A -- en.wiki.sipeed.com/hardware/en/
// modules/Gamepad.html has the protocol) and it IS physically attached to
// this unit (confirmed by photo, matching the wiki's layout exactly). But
// polling it -- at every frame, then throttled to every 10th, then even
// once via a plain diagnostic read -- reliably wedges the board: twice
// with periodic silent reboots (a serial capture spanning two full
// "maix-game: setup" banners with no exception between them) and once
// with a full, non-recovering hang (no output at all, not even the
// touch/scene prints that were working seconds earlier, requiring a
// DTR/RTS reset pulse to revive). framework-maixduino's Wire::
// writeTransmission/readTransmission (Wire.cpp) spin on the TX FIFO/
// ACTIVITY bits with only a tx_abrt_source check and no timeout, so
// whatever this module's I2C timing looks like from the K210 side isn't
// something that driver can wait out reliably. gamepad_scan below still
// implements the wiki's protocol (kept for reference/a future attempt
// with a patched driver or a hardware watchdog) but nothing calls it.
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

// Reads the first touch point, if any. Returns false (leaving *sx/*sy/
// *tx/*ty untouched) when nothing is touched; true otherwise, with
// *sx/*sy converted to panel space (maix_gamepad_layout.h::TouchToPanel)
// and *tx/*ty left as the untransformed raw reading (for the calibration
// print in maix_input_scan below -- there is no camera on this hardware,
// so that print is the only way to tell whether TouchToPanel, explicitly
// flagged there as unverified, is actually right).
bool touch_scan(int16_t* sx, int16_t* sy, int16_t* tx, int16_t* ty) {
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
  *tx = static_cast<int16_t>(((xh & 0x0F) << 8) | xl);
  *ty = static_cast<int16_t>(((yh & 0x0F) << 8) | yl);
  maix_gamepad::TouchToPanel(*tx, *ty, sx, sy);
  return true;
}

// Sipeed Gamepad module (GD32F150G, I2C1 at 400 kHz, no register select --
// every read just returns the module's latest state): a plain 2-byte
// requestFrom, byte 0 a bitmask of the D-pad + A/B/Select/Start, byte 1
// idle at 252 or overridden to 254 (X) / 253 (Y) -- there's no bit free in
// byte 0 for the two face buttons the wiki's own pinout table doesn't
// explain further, so this is exactly what the wiki's MaixPy sample
// (i2c.readfrom(0x4A, 2), sda=27, scl=24 -- this board's own I2C1 pins)
// decodes, transcribed as bit constants instead of the wiki's literal
// "N-252" test-output strings.
constexpr uint8_t kGamepadAddr = 0x4A;
constexpr uint8_t kGamepadB = 1 << 0;
constexpr uint8_t kGamepadA = 1 << 1;
constexpr uint8_t kGamepadSelect = 1 << 2;
constexpr uint8_t kGamepadStart = 1 << 3;
constexpr uint8_t kGamepadUp = 1 << 4;
constexpr uint8_t kGamepadDown = 1 << 5;
constexpr uint8_t kGamepadLeft = 1 << 6;
constexpr uint8_t kGamepadRight = 1 << 7;
constexpr uint8_t kGamepadExtraIdle = 252;
constexpr uint8_t kGamepadExtraX = 254;
constexpr uint8_t kGamepadExtraY = 253;

// Reads the module's current button state. Returns false (nothing
// touched *code/*extra) if the module doesn't answer -- e.g. not
// physically attached -- so a board without one just degrades to
// touch-only, the same fallback shape as touch_scan above.
bool gamepad_scan(uint8_t* code, uint8_t* extra) {
  if (Wire1.requestFrom(kGamepadAddr, static_cast<uint8_t>(2)) < 2)
    return false;
  *code = Wire1.read();
  *extra = Wire1.read();
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

// Whether the previous poll saw any touch at all, regardless of whether it
// landed on a gamepad region -- separate from g_prev's per-key state, so
// the calibration print below fires once per physical touch-down even
// when nothing maps to a key (the case most in need of a print, since
// g_prev alone would otherwise stay all-zero and never signal a change).
bool g_was_touching = false;

void maix_input_init(void) {
  Wire1.begin();
}

// Physical Gamepad module (case D-pad/A/B/X/Y/Select/Start): confirmed
// attached to this unit by photo, and gamepad_scan above implements its
// documented protocol. Polling it used to reliably wedge the board (see
// this file's header comment) because framework-maixduino's Wire.cpp had
// no timeout on its I2C wait loops; app/maix/patch_wire_i2c_timeout.py now
// patches that in (50ms, resetting the I2C peripheral on expiry) before
// every build, so a wedge can no longer hang forever. That patch is worth
// keeping regardless (a real bug in the vendor driver, zero cost when
// idle), but it didn't make the module usable: measured directly
// (micros() around gamepad_scan), every single call spent the full ~52ms
// timeout and failed -- the module never once acked -- and polling it
// even throttled to every 10th frame dragged touch_scan's own I2C1
// transactions into the same slowdown (the shared bus apparently doesn't
// recover cleanly just from resetting the K210 side), taking the game's
// per-frame time from ~20ms to ~130ms. No working button in exchange for
// a large responsiveness cost, so this stays unwired.
//
// Also confirmed the hard way: once the bus gets into that state, it
// stays there across firmware reboots and reflashes -- touch_scan itself
// started timing out too (measured, same ~50ms) with gamepad_scan fully
// uncalled, until the board was fully power-cycled (not just reset).
// Whatever's actually wedged (the touch controller, the gamepad module,
// or the bus lines themselves) doesn't lose that state just because the
// K210 side reinitializes I2C1 -- something external needs to actually
// lose power. Worth remembering before blaming new code for a hang: try
// a full power cycle before assuming a regression.

uint32_t maix_input_scan(void) {
  uint32_t key_bit = 0;

  int16_t x, y, tx, ty;
  if (touch_scan(&x, &y, &tx, &ty)) {
    using namespace maix_gamepad;
    const char* name = "(none)";
    if (InRect(x, y, kUp)) {
      key_bit |= 1u << MAIX_INPUT_UP;
      name = key_name(MAIX_INPUT_UP);
    } else if (InRect(x, y, kDown)) {
      key_bit |= 1u << MAIX_INPUT_DOWN;
      name = key_name(MAIX_INPUT_DOWN);
    } else if (InRect(x, y, kLeft)) {
      key_bit |= 1u << MAIX_INPUT_LEFT;
      name = key_name(MAIX_INPUT_LEFT);
    } else if (InRect(x, y, kRight)) {
      key_bit |= 1u << MAIX_INPUT_RIGHT;
      name = key_name(MAIX_INPUT_RIGHT);
    } else if (InCircle(x, y, kConfirm)) {
      key_bit |= 1u << MAIX_INPUT_C;
      name = key_name(MAIX_INPUT_C);
    } else if (InCircle(x, y, kCancel)) {
      key_bit |= 1u << MAIX_INPUT_B;
      name = key_name(MAIX_INPUT_B);
    }
    // Calibration aid: fires once per touch-down, mapped or not -- an
    // unmapped touch (name "(none)") is exactly the data needed to fix
    // TouchToPanel/the region geometry, and would never show up if this
    // only printed on a successful key resolution. (A verbose,
    // every-poll variant of this print, temporarily enabled to debug why
    // discrete taps were producing so few distinct readings, is what
    // actually diagonal-swept out TouchToPanel's real calibration -- see
    // its own comment; the I2C read itself is just noisy; this edge gate
    // was never the problem.)
    if (!g_was_touching) {
      Serial.print("maix-gamepad: touch raw=(");
      Serial.print(tx);
      Serial.print(",");
      Serial.print(ty);
      Serial.print(") panel=(");
      Serial.print(x);
      Serial.print(",");
      Serial.print(y);
      Serial.print(") -> ");
      Serial.println(name);
    }
    g_was_touching = true;
  } else {
    g_was_touching = false;
  }

  (void)gamepad_scan;  // see the file header comment -- deliberately unused

  return key_bit;
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
