// Shared geometry for the Maix Amigo's virtual gamepad overlay: the touch
// regions maix_gamepad.cxx draws and maix_input.cxx hit-tests are the same
// constants, so the two can never drift apart. Screen space is the LVGL
// display's own 320x240 landscape coordinate system (maix_display.cxx).
//
// Only Confirm (C) and Cancel (B) get buttons: grep finds no Input::A
// reference anywhere in mruby-rpg2k's scenes, so a third button would just
// spend screen space nothing reads.
#pragma once

#include <cstdint>

namespace maix_gamepad {

struct Rect {
  int16_t x0, y0, x1, y1;
};

struct Circle {
  int16_t cx, cy, r;
};

// D-pad: a 3x3 grid of square cells anchored at the bottom-left, center
// cell left as a deadzone (no key -- lets a thumb rest there between
// presses without triggering a direction).
constexpr int16_t kDpadCell = 36;
constexpr int16_t kDpadX = 0;
constexpr int16_t kDpadY = 240 - 3 * kDpadCell;

constexpr Rect kUp = {kDpadX + kDpadCell, kDpadY, kDpadX + 2 * kDpadCell,
                      kDpadY + kDpadCell};
constexpr Rect kDown = {kDpadX + kDpadCell, kDpadY + 2 * kDpadCell,
                        kDpadX + 2 * kDpadCell, kDpadY + 3 * kDpadCell};
constexpr Rect kLeft = {kDpadX, kDpadY + kDpadCell, kDpadX + kDpadCell,
                        kDpadY + 2 * kDpadCell};
constexpr Rect kRight = {kDpadX + 2 * kDpadCell, kDpadY + kDpadCell,
                         kDpadX + 3 * kDpadCell, kDpadY + 2 * kDpadCell};

// Confirm/Cancel: bottom-right, SNES-style diagonal (Confirm below-right of
// Cancel, both reachable by the same thumb that would rest near the D-pad's
// mirror position on the right edge).
constexpr Circle kConfirm = {272, 184, 28};
constexpr Circle kCancel = {220, 148, 22};

inline bool InRect(int16_t x, int16_t y, const Rect& r) {
  return x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1;
}

inline bool InCircle(int16_t x, int16_t y, const Circle& c) {
  const int32_t dx = x - c.cx;
  const int32_t dy = y - c.cy;
  return dx * dx + dy * dy <= static_cast<int32_t>(c.r) * c.r;
}

// The FT6X36 touch digitizer is a separate chip from the ST7789 display
// controller: MADCTL rotation (maix_display.cxx's DIR_YX_LRDU) repoints the
// display controller's own GRAM addressing, but the touch panel keeps
// reporting raw coordinates in its own fixed native space -- portrait,
// matching the driver's LCD_X_MAX/LCD_Y_MAX (Sipeed_ST7789/lcd.h): x in
// [0, kTouchNativeW), y in [0, kTouchNativeH).
constexpr int16_t kTouchNativeW = 240;  // LCD_X_MAX
constexpr int16_t kTouchNativeH = 320;  // LCD_Y_MAX

// Raw touch -> LVGL screen space, derived from DIR_YX_LRDU's MADCTL bits
// (0xE0: MY/MX/MV all set -- transpose plus both axes mirrored), the same
// transpose-and-mirror shape the display side already applies. UNLIKE the
// display's own direction/color fixes, this has not been independently
// confirmed against a real touch on real hardware -- nothing before this
// read raw touch coordinates at all (maix_input.cxx only ever asked "is
// anything touched"). If the overlay is visually in the right place but
// touching it drives the wrong key (or a mirrored/transposed one), this is
// the one function to fix; nothing else here should need to change.
inline void TouchToScreen(int16_t tx, int16_t ty, int16_t* sx, int16_t* sy) {
  *sx = static_cast<int16_t>((kTouchNativeH - 1) - ty);
  *sy = static_cast<int16_t>((kTouchNativeW - 1) - tx);
}

}  // namespace maix_gamepad
