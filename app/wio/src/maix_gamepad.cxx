// Virtual D-pad + Confirm/Cancel button overlay for the Maix Amigo's touch
// panel (PlatformIO side).
//
// The board has no physical buttons; this draws six white outline shapes
// (maix_gamepad_layout.h's Up/Down/Left/Right rects and Confirm/Cancel
// circles) directly to the panel's left/right margins via maix_panel_blit
// (see maix_display.cxx), bypassing LVGL entirely -- unlike an LVGL
// overlay, which is bounded by RPG2k's own 320x240 canvas, this lives
// outside it, in panel space, so it never covers a single pixel of the
// game's own screen and needs no per-frame re-raising: LVGL's flush_cb
// never touches the margins, so nothing the game draws can land on top of
// this. maix_input.cxx hit-tests raw touch (converted to the same panel
// space, maix_gamepad_layout.h::TouchToPanel) against the identical
// geometry to drive RGSS::Input.
//
// No text labels (no font renderer at this level -- LVGL's label widget
// isn't available outside its own canvas): Confirm is the lower-right
// circle, Cancel the upper-right one, consistent enough to learn by
// position alone.
//
// Deliberately its own translation unit rather than folded into
// maix_display.cxx: this is a UI/input concern layered on top of display
// bring-up, not part of it, so platformio.ini can drop it from an
// environment without touching the display HAL at all.

#include "maix.hxx"
#include "maix_gamepad_layout.h"

namespace {

// Sized for the larger of a D-pad cell (25x25) and a button's bounding
// box (up to 57x57 for the r=28 Confirm circle).
uint16_t s_buf[60 * 60];

void draw_rect_outline(const maix_gamepad::Rect& r, int16_t thickness) {
  const int32_t w = r.x1 - r.x0;
  const int32_t h = r.y1 - r.y0;
  for (int32_t y = 0; y < h; ++y) {
    for (int32_t x = 0; x < w; ++x) {
      const bool edge = x < thickness || y < thickness || x >= w - thickness ||
                        y >= h - thickness;
      s_buf[y * w + x] = edge ? 0xFFFF : 0x0000;
    }
  }
  maix_panel_blit(r.x0, r.y0, w, h, s_buf);
}

void draw_circle_outline(const maix_gamepad::Circle& c, int16_t thickness) {
  const int32_t d = c.r * 2 + 1;
  const int32_t rOuter2 = static_cast<int32_t>(c.r) * c.r;
  const int32_t rInner = c.r - thickness;
  const int32_t rInner2 = rInner > 0 ? rInner * rInner : 0;
  for (int32_t y = 0; y < d; ++y) {
    for (int32_t x = 0; x < d; ++x) {
      const int32_t dx = x - c.r;
      const int32_t dy = y - c.r;
      const int32_t dist2 = dx * dx + dy * dy;
      const bool ring = dist2 <= rOuter2 && dist2 >= rInner2;
      s_buf[y * d + x] = ring ? 0xFFFF : 0x0000;
    }
  }
  maix_panel_blit(c.cx - c.r, c.cy - c.r, d, d, s_buf);
}

}  // namespace

void maix_gamepad_create(void) {
  using namespace maix_gamepad;
  constexpr int16_t kThickness = 2;
  draw_rect_outline(kUp, kThickness);
  draw_rect_outline(kDown, kThickness);
  draw_rect_outline(kLeft, kThickness);
  draw_rect_outline(kRight, kThickness);
  draw_circle_outline(kConfirm, kThickness);
  draw_circle_outline(kCancel, kThickness);
}
