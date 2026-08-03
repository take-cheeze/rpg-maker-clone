// A tiny external accessor for an RGSS::Bitmap's raw pixel buffer, so other
// gems in the same binary can present into a Bitmap without knowing its
// (translation-unit-local) representation. Used by mruby-mvjs to copy the RPG
// Maker MV canvas onto the screen each frame.
#pragma once

#include <cstdint>

#include <mruby.h>

namespace rgss {

// If `v` is an RGSS::Bitmap, return its raw pixel buffer and set *w/*h to its
// dimensions; otherwise return nullptr. The buffer is LVGL ARGB8888, i.e. byte
// order B, G, R, A. It is owned by the Bitmap and stays valid (and un-moved) as
// long as the Bitmap lives, so callers may write into it in place. After
// writing, call bitmap_mark_dirty so Graphics.update repaints the sprites bound
// to this bitmap.
uint8_t* bitmap_pixels(mrb_state* M, mrb_value v, int* w, int* h);

// Mark an RGSS::Bitmap dirty so the next Graphics.update invalidates and
// repaints it. No-op if `v` is not a Bitmap.
void bitmap_mark_dirty(mrb_state* M, mrb_value v);

}  // namespace rgss
