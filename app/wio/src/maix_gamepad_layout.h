// Shared geometry for the Maix Amigo's virtual gamepad overlay: the touch
// regions maix_gamepad.cxx draws and maix_input.cxx hit-tests are the same
// constants, so the two can never drift apart.
//
// Coordinates are PANEL space (480x320 landscape, maix_display.cxx's
// kPanelW/kPanelH), not RPG2k's own 320x240 canvas: the D-pad and buttons
// live in the panel's left/right margins, outside the centered game
// canvas (x in [kOffsetX, kOffsetX+320), see maix_display.cxx) entirely,
// so nothing they draw can ever cover the game's own screen.
//
// Only Confirm (C) and Cancel (B) get buttons: grep finds no Input::A
// reference anywhere in mruby-rpg2k's scenes, so a third button would just
// spend margin space nothing reads.
#pragma once

#include <cstdint>

namespace maix_gamepad {

struct Rect {
  int16_t x0, y0, x1, y1;
};

struct Circle {
  int16_t cx, cy, r;
};

// D-pad: a 3x3 grid of square cells in the LEFT margin (panel x in
// [0, 80) -- see maix_display.cxx's kOffsetX), center cell left as a
// deadzone (no key -- lets a thumb rest there between presses without
// triggering a direction).
constexpr int16_t kDpadCell = 25;
constexpr int16_t kDpadX = 3;
constexpr int16_t kDpadY = 122;

constexpr Rect kUp = {kDpadX + kDpadCell, kDpadY, kDpadX + 2 * kDpadCell,
                      kDpadY + kDpadCell};
constexpr Rect kDown = {kDpadX + kDpadCell, kDpadY + 2 * kDpadCell,
                        kDpadX + 2 * kDpadCell, kDpadY + 3 * kDpadCell};
constexpr Rect kLeft = {kDpadX, kDpadY + kDpadCell, kDpadX + kDpadCell,
                        kDpadY + 2 * kDpadCell};
constexpr Rect kRight = {kDpadX + 2 * kDpadCell, kDpadY + kDpadCell,
                         kDpadX + 3 * kDpadCell, kDpadY + 2 * kDpadCell};

// Confirm/Cancel: stacked in the RIGHT margin (panel x in [400, 480) --
// kOffsetX + 320).
constexpr Circle kConfirm = {440, 200, 28};
constexpr Circle kCancel = {440, 120, 22};

inline bool InRect(int16_t x, int16_t y, const Rect& r) {
  return x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1;
}

inline bool InCircle(int16_t x, int16_t y, const Circle& c) {
  const int32_t dx = x - c.cx;
  const int32_t dy = y - c.cy;
  return dx * dx + dy * dy <= static_cast<int32_t>(c.r) * c.r;
}

// The FT6X36 touch digitizer is a separate chip from the ST7789 display
// controller and keeps reporting raw coordinates in its own native space
// regardless of the display's own MADCTL rotation. Confirmed on real
// hardware with a diagonal drag sweep (top-left to bottom-right) logged
// through maix_input.cxx's raw-touch print: filtering out isolated
// single-sample glitches (the raw I2C read is noisy -- a real, if
// imperfect, digitizer, not a bug in this code), ty rose smoothly from
// ~235 to ~472 while tx fell smoothly from ~143 to ~4 over the same
// sweep. That is a clean 1:1 match to the panel's TRUE native portrait
// resolution (320x480 -- the panel spec app/maix/README.md always
// quoted, not the smaller 240x320 LCD_X_MAX/LCD_Y_MAX the display side
// also turned out to be wrong to trust, see maix_display.cxx's own file
// header comment) once one axis is inverted: ty maps directly to panel
// x, and tx maps to panel y *inverted* (native tx=0 is the panel's
// bottom edge, not its top).
constexpr int16_t kTouchNativeW = 320;  // native tx range (portrait width)
constexpr int16_t kTouchNativeH = 480;  // native ty range (portrait height)

// Raw touch -> panel space, confirmed against a real diagonal sweep (see
// kTouchNativeW/H's own comment) -- unlike the display's own direction/
// color fixes this was derived from exactly one sweep, not cross-checked
// with a second one, so a further correction (an offset, or a sign flip
// found to still be off at one edge) would not be a surprise.
inline void TouchToPanel(int16_t tx, int16_t ty, int16_t* px, int16_t* py) {
  *px = static_cast<int16_t>((int32_t)ty * 480 / kTouchNativeH);
  *py =
      static_cast<int16_t>((int32_t)(kTouchNativeW - tx) * 320 / kTouchNativeW);
}

}  // namespace maix_gamepad
