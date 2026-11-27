// GFX_BACKEND (gfx.hxx) on LVGL: a node is an lv_obj_t, a sprite an lv_canvas,
// a view an lv_image_dsc_t that the image decoder below expands, and the frame
// LVGL's timer handler. Every port draws through this; the ports' display
// drivers make the lv_display_t it draws into.

#include "gfx.hxx"

#include <lvgl.h>
#include <src/draw/lv_image_decoder_private.h>

#include <algorithm>
#include <cstdio>

namespace rgss {
namespace gfx {

static_assert(sizeof(PixelFormat) == sizeof(lv_color_format_t),
              "a Bitmap's format has lv_color_format_t's size");
static_assert(int{kPixelI8} == int{LV_COLOR_FORMAT_I8} &&
                  int{kPixelRGB888} == int{LV_COLOR_FORMAT_RGB888} &&
                  int{kPixelARGB8888} == int{LV_COLOR_FORMAT_ARGB8888},
              "PixelFormat is LVGL's numbering");
static_assert(kScaleOne == LV_SCALE_NONE, "kScaleOne is LVGL's unscaled");
static_assert(sizeof(View::backend) == sizeof(lv_image_dsc_t) &&
                  alignof(View) >= alignof(lv_image_dsc_t),
              "a View's backend bytes are an lv_image_dsc_t");

namespace {

lv_obj_t* obj(Node* n) {
  return reinterpret_cast<lv_obj_t*>(n);
}
Node* node(lv_obj_t* o) {
  return reinterpret_cast<Node*>(o);
}
lv_display_t* disp(Display* d) {
  return reinterpret_cast<lv_display_t*>(d);
}
lv_color_format_t cf(PixelFormat f) {
  return static_cast<lv_color_format_t>(f);
}
lv_image_dsc_t& dsc_of(View* v) {
  return *reinterpret_cast<lv_image_dsc_t*>(v->backend);
}

// LVGL fires LV_EVENT_DELETE when an object is destroyed, including when its
// parent is deleted and takes the whole subtree with it, so a wrapper never
// outlives its object (node_released).
void on_delete(lv_event_t* e) {
  lv_obj_t* o = static_cast<lv_obj_t*>(lv_event_get_target(e));
  if (void* ud = lv_obj_get_user_data(o))
    node_released(ud);
}

// ---- Views: an image decoder that asks the engine for the rows of each strip
// LVGL renders, so the picture never exists whole.

// Marks a view's header; its data pointer also points back at the view.
constexpr uint16_t kViewFlag = LV_IMAGE_FLAGS_USER8;
const View* view_of(const void* src) {
  const auto* img = static_cast<const lv_image_dsc_t*>(src);
  if (!(img->header.flags & kViewFlag) ||
      img->data != static_cast<const void*>(img))
    return nullptr;
  return reinterpret_cast<const View*>(img);
}

lv_result_t view_info(lv_image_decoder_t*,
                      lv_image_decoder_dsc_t* dsc,
                      lv_image_header_t* header) {
  if (dsc->src_type != LV_IMAGE_SRC_VARIABLE || !view_of(dsc->src))
    return LV_RESULT_INVALID;
  *header = static_cast<const lv_image_dsc_t*>(dsc->src)->header;
  return LV_RESULT_OK;
}

lv_result_t view_open(lv_image_decoder_t*, lv_image_decoder_dsc_t* dsc) {
  // No whole image: img_decode_and_draw then draws the rows get_area yields.
  dsc->decoded = nullptr;
  dsc->user_data = nullptr;
  return LV_RESULT_OK;
}

lv_result_t view_get_area(lv_image_decoder_t*,
                          lv_image_decoder_dsc_t* dsc,
                          const lv_area_t* full_area,
                          lv_area_t* decoded_area) {
  DrawHold hold;
  const View* v = view_of(dsc->src);
  const int32_t y1 =
      decoded_area->y1 == LV_COORD_MIN ? full_area->y1 : decoded_area->y2 + 1;
  if (y1 > full_area->y2)
    return LV_RESULT_INVALID;
  const lv_color_format_t f = static_cast<lv_color_format_t>(
      static_cast<const lv_image_dsc_t*>(dsc->src)->header.cf);
  const unsigned bpp = lv_color_format_get_size(f);
  const int32_t w = lv_area_get_width(full_area);
  const int32_t chunk = view_chunk_rows(*v, w, bpp);
  const int32_t rows = std::min<int32_t>(chunk, full_area->y2 - y1 + 1);
  auto* buf = static_cast<lv_draw_buf_t*>(dsc->user_data);
  lv_draw_buf_t* out =
      buf ? lv_draw_buf_reshape(buf, f, w, rows, LV_STRIDE_AUTO) : nullptr;
  if (!out) {
    if (buf)
      lv_draw_buf_destroy(buf);
    buf = out = lv_draw_buf_create(
        w, std::min<int32_t>(chunk, lv_area_get_height(full_area)), f,
        LV_STRIDE_AUTO);
    dsc->user_data = buf;
    if (!buf) {
      std::fprintf(stderr, "[RGSS] sprite draw: no memory for %dx%d rows\n",
                   static_cast<int>(w), static_cast<int>(chunk));
      return LV_RESULT_INVALID;
    }
    out = lv_draw_buf_reshape(buf, f, w, rows, LV_STRIDE_AUTO);
  }
  view_fill(*v, full_area->x1, full_area->x2, y1, rows, out->data,
            out->header.stride, bpp);
  decoded_area->x1 = full_area->x1;
  decoded_area->x2 = full_area->x2;
  decoded_area->y1 = y1;
  decoded_area->y2 = y1 + rows - 1;
  dsc->decoded = out;
  return LV_RESULT_OK;
}

void view_close(lv_image_decoder_t*, lv_image_decoder_dsc_t* dsc) {
  if (dsc->user_data)
    lv_draw_buf_destroy(static_cast<lv_draw_buf_t*>(dsc->user_data));
  dsc->user_data = nullptr;
}

void view_delete(lv_event_t* e) {
  view_destroy(static_cast<View*>(lv_event_get_user_data(e)));
}

}  // namespace

// ---- Display and frame ------------------------------------------------------

// A style-less, display-sized container one level below the active screen, so
// a platform shell can move the whole game picture as a single object:
// Android's window is phone-shaped while the game is 4:3, and the shell
// centres the root in the leftover letterbox (src/android_vpad_ui.cxx).
// Everywhere else it sits at (0,0), where it renders nothing and changes
// nothing. Scenes only ever add children, and the percentage size tracks
// resolution changes by itself.
Node* root(Display* d) {
  static lv_obj_t* r = nullptr;
  if (r)
    return node(r);
  r = lv_obj_create(lv_display_get_screen_active(disp(d)));
  lv_obj_remove_style_all(r);
  lv_obj_remove_flag(r, static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_SCROLLABLE |
                                                   LV_OBJ_FLAG_CLICKABLE));
  lv_obj_set_size(r, lv_pct(100), lv_pct(100));
  return node(r);
}

void display_size(Display* d, int32_t& w, int32_t& h) {
  w = lv_display_get_horizontal_resolution(disp(d));
  h = lv_display_get_vertical_resolution(disp(d));
}

void frame_draw() {
  lv_timer_handler();
  lv_task_handler();
}

uint32_t tick_ms() {
  return lv_tick_get();
}

void delay_ms(uint32_t ms) {
  lv_delay_ms(ms);
}

// lv_snapshot_take re-renders the active screen's object tree into a fresh
// buffer, which is the only capture that works on every port -- the SDL
// window, the terminal framebuffer and the wasm canvas all buffer differently,
// and two of them render partially. LVGL's ARGB8888 is B, G, R, A, a Bitmap's
// layout.
bool can_snapshot() {
  return LV_USE_SNAPSHOT;
}

SnapResult snapshot_take(Display* d, Snapshot& out) {
#if LV_USE_SNAPSHOT
  lv_obj_t* screen = lv_display_get_screen_active(disp(d));
  if (!screen)
    return SnapResult::kNoScreen;
  lv_draw_buf_t* snap = lv_snapshot_take(screen, LV_COLOR_FORMAT_ARGB8888);
  if (!snap)
    return SnapResult::kFailed;
  out.w = snap->header.w;
  out.h = snap->header.h;
  out.stride = snap->header.stride;
  out.data = snap->data;
  out.impl = snap;
  return SnapResult::kOk;
#else
  (void)d;
  (void)out;
  return SnapResult::kFailed;
#endif
}

void snapshot_release(Snapshot& s) {
  lv_draw_buf_destroy(static_cast<lv_draw_buf_t*>(s.impl));
  s.impl = nullptr;
}

// ---- Nodes ------------------------------------------------------------------

Node* sprite_new(Node* parent) {
  return node(lv_canvas_create(obj(parent)));
}

Node* viewport_new(Node* parent) {
  lv_obj_t* outer = lv_obj_create(obj(parent));
  lv_obj_remove_style_all(outer);
  lv_obj_remove_flag(outer, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_scrollbar_mode(outer, LV_SCROLLBAR_MODE_OFF);

  // Inner content layer: children beyond the viewport bounds must survive here
  // (only the outer frame clips), so let it overflow.
  lv_obj_t* inner = lv_obj_create(outer);
  lv_obj_remove_style_all(inner);
  lv_obj_remove_flag(inner, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(inner, LV_OBJ_FLAG_OVERFLOW_VISIBLE);
  return node(outer);
}

Node* viewport_content(Node* frame) {
  return node(lv_obj_get_child(obj(frame), 0));
}

// The frame's only other child is the content layer (index 0), and node_raise
// keeps the overlay last, so index 1 identifies it.
Node* viewport_overlay(Node* frame, bool create) {
  if (lv_obj_t* existing = lv_obj_get_child(obj(frame), 1))
    return node(existing);
  if (!create)
    return nullptr;
  lv_obj_t* ov = lv_canvas_create(obj(frame));
  lv_obj_remove_style_all(ov);
  lv_obj_set_pos(ov, 0, 0);
  lv_obj_remove_flag(ov, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_move_foreground(ov);
  return node(ov);
}

void node_bind(Node* n, void* owner) {
  lv_obj_set_user_data(obj(n), owner);
  lv_obj_add_event_cb(obj(n), on_delete, LV_EVENT_DELETE, nullptr);
}

void node_delete(Node* n) {
  lv_obj_delete(obj(n));
}

Node* node_parent(Node* n) {
  return node(lv_obj_get_parent(obj(n)));
}

void node_raise(Node* n) {
  lv_obj_move_foreground(obj(n));
}

void node_reparent(Node* n, Node* parent) {
  lv_obj_set_parent(obj(n), obj(parent));
}

void node_invalidate(Node* n) {
  lv_obj_invalidate(obj(n));
}

void node_set_pos(Node* n, int32_t x, int32_t y) {
  lv_obj_set_pos(obj(n), x, y);
}

void node_set_x(Node* n, int32_t x) {
  lv_obj_set_x(obj(n), x);
}

void node_set_y(Node* n, int32_t y) {
  lv_obj_set_y(obj(n), y);
}

void node_set_size(Node* n, int32_t w, int32_t h) {
  lv_obj_set_size(obj(n), w, h);
}

void node_set_hidden(Node* n, bool hidden) {
  if (hidden)
    lv_obj_add_flag(obj(n), LV_OBJ_FLAG_HIDDEN);
  else
    lv_obj_remove_flag(obj(n), LV_OBJ_FLAG_HIDDEN);
}

// ---- Sprites ----------------------------------------------------------------

void sprite_set_pixels(Node* n,
                       uint8_t* px,
                       int32_t w,
                       int32_t h,
                       PixelFormat f) {
  lv_canvas_set_buffer(obj(n), px, w, h, cf(f));
}

void sprite_clear(Node* n) {
  lv_image_set_src(obj(n), nullptr);
}

// The object-level style opacity multiplies the image's own alpha at blit
// time.
void sprite_set_opacity(Node* n, uint8_t opa) {
  lv_obj_set_style_opa(obj(n), static_cast<lv_opa_t>(opa), 0);
}

void sprite_set_scale_x(Node* n, uint32_t scale) {
  lv_image_set_scale_x(obj(n), scale);
}

void sprite_set_scale_y(Node* n, uint32_t scale) {
  lv_image_set_scale_y(obj(n), scale);
}

void sprite_set_rotation(Node* n, int32_t tenths) {
  lv_image_set_rotation(obj(n), tenths);
}

void sprite_set_pivot(Node* n, int32_t x, int32_t y) {
  lv_image_set_pivot(obj(n), x, y);
}

bool sprite_transformed(Node* n) {
  return lv_image_get_scale_x(obj(n)) != LV_SCALE_NONE ||
         lv_image_get_scale_y(obj(n)) != LV_SCALE_NONE ||
         lv_image_get_rotation(obj(n)) != 0;
}

void sprite_set_blend(Node* n, Blend b) {
  lv_blend_mode_t mode = LV_BLEND_MODE_NORMAL;
  if (b == Blend::kAdd)
    mode = LV_BLEND_MODE_ADDITIVE;
  else if (b == Blend::kSubtract)
    mode = LV_BLEND_MODE_SUBTRACTIVE;
  lv_obj_set_style_blend_mode(obj(n), mode, 0);
}

bool views_ready() {
  static bool registered = false;
  if (registered)
    return true;
  lv_image_decoder_t* dec = lv_image_decoder_create();
  if (!dec)
    return false;
  lv_image_decoder_set_info_cb(dec, view_info);
  lv_image_decoder_set_open_cb(dec, view_open);
  lv_image_decoder_set_get_area_cb(dec, view_get_area);
  lv_image_decoder_set_close_cb(dec, view_close);
  dec->name = "rgss-sprite";
  registered = true;
  return true;
}

View* sprite_view(Node* n) {
  for (uint32_t i = 0, c = lv_obj_get_event_count(obj(n)); i < c; ++i) {
    lv_event_dsc_t* d = lv_obj_get_event_dsc(obj(n), i);
    if (lv_event_dsc_get_cb(d) == view_delete)
      return static_cast<View*>(lv_event_dsc_get_user_data(d));
  }
  return nullptr;
}

void sprite_attach_view(Node* n, View* v) {
  lv_obj_add_event_cb(obj(n), view_delete, LV_EVENT_DELETE, v);
}

void sprite_show_view(Node* n, View* v, PixelFormat f, int32_t w, int32_t h) {
  lv_image_dsc_t& d = dsc_of(v);
  lv_image_header_t& hd = d.header;
  hd = lv_image_header_t{};
  hd.magic = LV_IMAGE_HEADER_MAGIC;
  hd.cf = f;
  hd.flags = kViewFlag;
  hd.w = w;
  hd.h = h;
  hd.stride = w * pixel_size(f);
  d.data = reinterpret_cast<const uint8_t*>(&d);
  d.data_size = 0;
  lv_image_set_src(obj(n), &d);
}

}  // namespace gfx
}  // namespace rgss

// The ports hand their LVGL display over here (src/main.cxx, app/psp/main.cxx,
// the Wio/Maix mains, the host harness).
extern "C" void rgss_set_display(mrb_state* M, lv_display_t* display) {
  rgss::gfx::display_attached(M,
                              reinterpret_cast<rgss::gfx::Display*>(display));

  // The game screen is what shows wherever no sprite covers it, so it must be
  // the black RPG Maker draws outside the map -- LVGL's default theme paints it
  // light grey and hangs scrollbars off the edges, both of which showed up as
  // artefacts next to a genuine RPG_RT frame. Nothing about a game
  // screen scrolls, either.
  if (lv_obj_t* scr = lv_display_get_screen_active(display)) {
    lv_obj_set_style_bg_color(scr, lv_color_black(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(scr, LV_SCROLLBAR_MODE_OFF);
  }
}

// Exported for the platform shells (src/android_vpad_ui.cxx centres it under
// __ANDROID__): the container every game object hangs off.
extern "C" lv_obj_t* rgss_game_root_obj(lv_display_t* disp) {
  return reinterpret_cast<lv_obj_t*>(
      rgss::gfx::root(reinterpret_cast<rgss::gfx::Display*>(disp)));
}
