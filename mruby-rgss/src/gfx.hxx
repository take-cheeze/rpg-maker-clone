// GFX_BACKEND: what the RGSS natives (lib.cxx) need from whatever puts their
// pictures on a screen. The engine builds a display list of nodes -- a root,
// Viewports (a clipping frame around a scrolled content layer) and Sprites --
// edits it as the game runs, and asks the backend to draw it once a frame.
// gfx_lvgl.cxx implements it on LVGL for every port. The engine sees no
// backend type: a Node is opaque to it.
#pragma once

#include <cstddef>
#include <cstdint>

struct mrb_state;

namespace rgss {

// The layouts a Bitmap's pixels come in: bytes B, G, R(, A) per pixel, or one
// palette index per pixel (I8). The numbers are LVGL's, so gfx_lvgl.cxx hands
// them over unconverted; a plain enum, so it has lv_color_format_t's size under
// the same ABI (both checked there).
enum PixelFormat {
  kPixelI8 = 0x0A,
  kPixelRGB888 = 0x0F,
  kPixelARGB8888 = 0x10
};

// uint8_t, as lv_color_format_get_size answers, so arithmetic on it promotes
// the way it did.
constexpr uint8_t pixel_size(PixelFormat f) {
  return f == kPixelARGB8888 ? 4
         : f == kPixelRGB888 ? 3
         : f == kPixelI8     ? 1
                             : 0;
}

namespace gfx {

struct Node;
struct Display;

// The scale a sprite is drawn at when not zoomed (1.0).
constexpr uint32_t kScaleOne = 256;

enum class Blend : uint8_t { kNormal, kAdd, kSubtract };

// A sprite picture whose rows the engine expands while the backend draws it
// (DRAW_TIME_SPRITE in lib.cxx) instead of a pixel buffer. The engine derives
// its view from this; `backend` is the backend's state for it and must stay
// first (the LVGL backend's is an lv_image_dsc_t, which points at itself).
constexpr size_t kViewBackendBytes = 16 + 3 * sizeof(void*);
struct View {
  alignas(void*) unsigned char backend[kViewBackendBytes];
};

// ---- Display and frame ------------------------------------------------------

// The node every game-side picture hangs off, made on first use.
Node* root(Display* d);
void display_size(Display* d, int32_t& w, int32_t& h);
// Draws what changed since the last frame.
void frame_draw();
uint32_t tick_ms();
void delay_ms(uint32_t ms);

// The screen as drawn, ARGB8888 rows `stride` bytes apart.
struct Snapshot {
  int32_t w, h;
  uint32_t stride;
  const uint8_t* data;
  void* impl;
};
enum class SnapResult { kOk, kNoScreen, kFailed };
bool can_snapshot();
SnapResult snapshot_take(Display* d, Snapshot& out);
void snapshot_release(Snapshot& s);

// ---- Nodes ------------------------------------------------------------------

Node* sprite_new(Node* parent);
// A clipping frame with its content layer (viewport_content), which may
// overflow it and which the frame's position does not scroll.
Node* viewport_new(Node* parent);
Node* viewport_content(Node* frame);
// The colour layer drawn over the content, made when `create` is set.
Node* viewport_overlay(Node* frame, bool create);

// Ties `owner` (the wrapper's RData) to the node: when the node goes, by
// node_delete or with its parent, the backend calls node_released(owner).
void node_bind(Node* n, void* owner);
void node_delete(Node* n);
Node* node_parent(Node* n);
// Draws the node over its siblings; ties keep the order of the raises.
void node_raise(Node* n);
void node_reparent(Node* n, Node* parent);
// The node's pixels changed: draw it again.
void node_invalidate(Node* n);
void node_set_pos(Node* n, int32_t x, int32_t y);
void node_set_x(Node* n, int32_t x);
void node_set_y(Node* n, int32_t y);
void node_set_size(Node* n, int32_t w, int32_t h);
// A hidden node hides its children too.
void node_set_hidden(Node* n, bool hidden);

// ---- Sprites ----------------------------------------------------------------

// Draws `px` (w x h in `f`, not copied: the caller keeps it alive).
void sprite_set_pixels(Node* n,
                       uint8_t* px,
                       int32_t w,
                       int32_t h,
                       PixelFormat f);
void sprite_clear(Node* n);
void sprite_set_opacity(Node* n, uint8_t opa);
void sprite_set_scale_x(Node* n, uint32_t scale);
void sprite_set_scale_y(Node* n, uint32_t scale);
// Tenths of a degree clockwise, about the pivot.
void sprite_set_rotation(Node* n, int32_t tenths);
void sprite_set_pivot(Node* n, int32_t x, int32_t y);
bool sprite_transformed(Node* n);
void sprite_set_blend(Node* n, Blend b);

// Whether views can be drawn at all; the first call sets them up.
bool views_ready();
View* sprite_view(Node* n);
// The node owns `v` from here: view_destroy runs when the node goes.
void sprite_attach_view(Node* n, View* v);
// Draws `v` as w x h of `f`, untransformed.
void sprite_show_view(Node* n, View* v, PixelFormat f, int32_t w, int32_t h);

// ---- Engine side: defined in lib.cxx, called by the backend
// ------------------

void node_released(void* owner);
// Held while the backend draws, when a collection would delete the nodes it
// walks.
struct DrawHold {
  DrawHold();
  ~DrawHold();
  DrawHold(const DrawHold&) = delete;
};
// How many rows of `v`, `w` pixels of `bpp` bytes wide, to expand at a time.
int32_t view_chunk_rows(const View& v, int32_t w, unsigned bpp);
// Rows [y, y + rows) of `v`, pixels x1..x2, into `out` (`stride` apart).
void view_fill(const View& v,
               int32_t x1,
               int32_t x2,
               int32_t y,
               int32_t rows,
               uint8_t* out,
               uint32_t stride,
               unsigned bpp);
void view_destroy(View* v);
// The port's display, for Graphics.width and friends.
void display_attached(mrb_state* M, Display* d);

}  // namespace gfx
}  // namespace rgss
