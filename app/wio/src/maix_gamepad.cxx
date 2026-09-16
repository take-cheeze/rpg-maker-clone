// Virtual D-pad + Confirm/Cancel button overlay for the Maix Amigo's touch
// panel (PlatformIO side).
//
// The board has no physical buttons; this draws six translucent LVGL
// shapes (maix_gamepad_layout.h's Up/Down/Left/Right rects and Confirm/
// Cancel circles) as the last children of the active screen, on top of
// whatever the current RPG2k scene rendered, and maix_input.cxx hit-tests
// raw touch against the identical geometry to drive RGSS::Input. Low
// opacity is deliberate: RPG2k's own message window usually sits in the
// bottom third of the screen, the same real estate the D-pad and buttons
// need, so the controls stay legible as an outline rather than blocking
// text underneath.
//
// Deliberately its own translation unit rather than folded into
// maix_display.cxx: this is a UI/input concern layered on top of display
// bring-up, not part of it, so platformio.ini can drop it from an
// environment without touching the display HAL at all.

#include "maix.hxx"
#include "maix_gamepad_layout.h"

#include <lvgl.h>

namespace {

lv_obj_t* g_root = nullptr;

// Outline only, no fill: a translucent fill over the D-pad's ~5,200 px^2
// footprint was enough to drop the title screen's own solid-color fraction
// below maix-smoke's own threshold (0.459 -> 0.400, confirmed under
// Renode) -- confirmed the same way the display flush's own band count
// was confirmed, by actually measuring it, not guessing. An outline reads
// fine as a button boundary and touches only a handful of border pixels.
void style_outline(lv_obj_t* obj, lv_opa_t border_opa) {
  lv_obj_set_style_bg_opa(obj, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_color(obj, lv_color_white(), 0);
  lv_obj_set_style_border_width(obj, 2, 0);
  lv_obj_set_style_border_opa(obj, border_opa, 0);
}

void make_rect(lv_obj_t* parent, const maix_gamepad::Rect& r) {
  lv_obj_t* o = lv_obj_create(parent);
  lv_obj_remove_style_all(o);
  lv_obj_clear_flag(o, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(o, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_pos(o, r.x0, r.y0);
  lv_obj_set_size(o, r.x1 - r.x0, r.y1 - r.y0);
  style_outline(o, LV_OPA_70);
}

void make_circle(lv_obj_t* parent,
                 const maix_gamepad::Circle& c,
                 const char* label) {
  lv_obj_t* o = lv_obj_create(parent);
  lv_obj_remove_style_all(o);
  lv_obj_clear_flag(o, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(o, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_pos(o, c.cx - c.r, c.cy - c.r);
  lv_obj_set_size(o, c.r * 2, c.r * 2);
  lv_obj_set_style_radius(o, LV_RADIUS_CIRCLE, 0);
  style_outline(o, LV_OPA_80);

  lv_obj_t* txt = lv_label_create(o);
  lv_label_set_text(txt, label);
  lv_obj_set_style_text_color(txt, lv_color_white(), 0);
  lv_obj_center(txt);
}

}  // namespace

void maix_gamepad_create(void) {
  g_root = lv_obj_create(lv_screen_active());
  lv_obj_remove_style_all(g_root);
  lv_obj_clear_flag(g_root, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(g_root, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_pos(g_root, 0, 0);
  lv_obj_set_size(g_root, 320, 240);

  make_rect(g_root, maix_gamepad::kUp);
  make_rect(g_root, maix_gamepad::kDown);
  make_rect(g_root, maix_gamepad::kLeft);
  make_rect(g_root, maix_gamepad::kRight);
  make_circle(g_root, maix_gamepad::kConfirm, "C");
  make_circle(g_root, maix_gamepad::kCancel, "B");
}

void maix_gamepad_foreground(void) {
  if (g_root)
    lv_obj_move_foreground(g_root);
}
