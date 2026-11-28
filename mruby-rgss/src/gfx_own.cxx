// GFX_BACKEND (gfx.hxx) without LVGL (RGSS_GFX_OWN): a display list of root,
// viewport and sprite nodes, drawn into the port's RGB565 strip a dirty
// rectangle at a time and pushed with the port's flush (rgss_gfx_own.hxx).
//
// LVGL_PIXELS: every pixel is the one gfx_lvgl.cxx's software renderer writes
// for the same list -- the arithmetic of lv_draw_sw_blend_to_rgb565.c
// (rgb888_image_blend, argb8888_image_blend, lv_color_24_16_mix), the opacity
// path of lv_obj_refr and lv_obj_init_draw_image_dsc, and LVGL's clipping (a
// node clips its children to its own area, the content layer's
// OVERFLOW_VISIBLE included, since it has no extra draw size). The pixels do
// not depend on the strip, so frame hashes match LVGL's.
//
// Nothing is allocated while drawing: the strip is the port's, view rows go
// through a static scratch, and the dirty list is fixed (a full screen when it
// runs out).

#ifdef RGSS_GFX_OWN

#include "gfx.hxx"
#include "rgss_gfx_own.hxx"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

namespace rgss {
namespace gfx {

namespace {

// LVGL's LV_OPA_MIN / LV_OPA_MAX: at most MIN draws nothing, at least MAX
// covers.
constexpr uint8_t kOpaMin = 2;
constexpr uint8_t kOpaMax = 253;

struct Area {
  int16_t x1 = 0, y1 = 0, x2 = -1, y2 = -1;
  bool empty() const { return x2 < x1 || y2 < y1; }
  int32_t area() const {
    return empty() ? 0 : int32_t{x2 - x1 + 1} * int32_t{y2 - y1 + 1};
  }
  bool operator==(const Area& o) const {
    return (empty() && o.empty()) ||
           (x1 == o.x1 && y1 == o.y1 && x2 == o.x2 && y2 == o.y2);
  }
  bool operator!=(const Area& o) const { return !(*this == o); }
};

Area intersect(const Area& a, const Area& b) {
  Area r;
  r.x1 = std::max(a.x1, b.x1);
  r.y1 = std::max(a.y1, b.y1);
  r.x2 = std::min(a.x2, b.x2);
  r.y2 = std::min(a.y2, b.y2);
  return r;
}

Area join(const Area& a, const Area& b) {
  Area r;
  r.x1 = std::min(a.x1, b.x1);
  r.y1 = std::min(a.y1, b.y1);
  r.x2 = std::max(a.x2, b.x2);
  r.y2 = std::max(a.y2, b.y2);
  return r;
}

// An area in absolute coordinates, clamped into int16_t range: whatever lies
// past it is off any screen this draws.
Area clamp_rect(int32_t x, int32_t y, int32_t w, int32_t h) {
  Area r;
  if (w <= 0 || h <= 0)
    return r;
  auto c = [](int32_t v) {
    return static_cast<int16_t>(
        std::max<int32_t>(-32768, std::min<int32_t>(v, 32767)));
  };
  r.x1 = c(x);
  r.y1 = c(y);
  r.x2 = c(x + w - 1);
  r.y2 = c(y + h - 1);
  return r;
}

enum class Kind : uint8_t { kRoot, kFrame, kContent, kSprite };
enum class Src : uint8_t { kNone, kPixels, kView };

}  // namespace

struct Node {
  Node* parent = nullptr;
  Node* first = nullptr;
  Node* last = nullptr;
  Node* prev = nullptr;
  Node* next = nullptr;
  void* owner = nullptr;
  View* view = nullptr;  // owned
  const uint8_t* px = nullptr;
  int32_t x = 0, y = 0;
  // An explicit size; a sprite without one is its picture's size, as an LVGL
  // image is LV_SIZE_CONTENT.
  int32_t w = 0, h = 0;
  int32_t ix = 0, iy = 0;  // the picture's absolute origin, this frame
  int16_t iw = 0, ih = 0;  // the picture's size
  // `vis`: where this frame draws the node itself (a sprite's picture, a
  // frame's colour); `drawn`: where the last frame did; `clip`: where a
  // container's children may draw.
  Area vis, drawn, clip;
  uint16_t scale_x = kScaleOne, scale_y = kScaleOne;
  int16_t rotation = 0;
  Kind kind = Kind::kSprite;
  Src src = Src::kNone;
  PixelFormat format = kPixelARGB8888;
  uint8_t opa = 255;
  Blend blend = Blend::kNormal;
  uint8_t color[4] = {0, 0, 0, 0};  // a frame's B, G, R, A overlay
  bool sized = false;
  bool hidden = false;
  // Redraw the subtree / only the frame's colour.
  bool dirty = true;
  bool recolor = false;
};

struct Display {
  RgssOwnConfig cfg;
  Node root;
  uint32_t last_draw = 0;
  bool drawn_once = false;
  // DIRTY_LIST: areas to draw this frame; a full list becomes the screen
  // (LVGL's LV_INV_BUF_SIZE).
  static constexpr int kDirtyMax = 32;
  Area dirty[kDirtyMax];
  int ndirty = 0;
};

namespace {

Display* g_disp = nullptr;

Area screen_rect(const Display& d) {
  return clamp_rect(0, 0, d.cfg.width, d.cfg.height);
}

void add_dirty(Area r) {
  Display* d = g_disp;
  if (!d)
    return;
  r = intersect(r, screen_rect(*d));
  if (r.empty())
    return;
  // Joined with any area it overlaps whose union is smaller than the two
  // apart, until none is (LVGL's lv_refr_join_area rule).
  for (bool merged = true; merged;) {
    merged = false;
    for (int i = 0; i < d->ndirty; ++i) {
      const Area u = join(r, d->dirty[i]);
      if (!intersect(r, d->dirty[i]).empty() &&
          u.area() < r.area() + d->dirty[i].area()) {
        r = u;
        d->dirty[i] = d->dirty[--d->ndirty];
        merged = true;
        break;
      }
    }
  }
  if (d->ndirty == Display::kDirtyMax) {
    d->dirty[0] = screen_rect(*d);
    d->ndirty = 1;
    return;
  }
  d->dirty[d->ndirty++] = r;
}

void warn_once(bool& warned, const char* what) {
  if (warned)
    return;
  warned = true;
  std::fprintf(stderr, "[RGSS] gfx: %s\n", what);
}

void unlink(Node* n) {
  Node* p = n->parent;
  if (!p)
    return;
  (n->prev ? n->prev->next : p->first) = n->next;
  (n->next ? n->next->prev : p->last) = n->prev;
  n->parent = n->prev = n->next = nullptr;
}

void append(Node* p, Node* n) {
  n->parent = p;
  n->prev = p->last;
  n->next = nullptr;
  (p->last ? p->last->next : p->first) = n;
  p->last = n;
}

void touch(Node* n) {
  n->dirty = true;
}

Node* new_node(Node* parent, Kind kind) {
  Node* n = new (std::nothrow) Node();
  if (!n) {
    std::fprintf(stderr, "[RGSS] gfx: no memory for a %s node\n",
                 kind == Kind::kSprite ? "sprite" : "viewport");
    std::abort();
  }
  n->kind = kind;
  if (kind != Kind::kSprite)
    n->sized = true;
  append(parent, n);
  return n;
}

// The node and its subtree go; what they drew is drawn over.
void free_subtree(Node* n) {
  while (Node* c = n->first) {
    unlink(c);
    free_subtree(c);
  }
  add_dirty(n->drawn);
  if (n->owner)
    node_released(n->owner);
  if (n->view)
    view_destroy(n->view);
  delete n;
}

int32_t node_w(const Node* n) {
  return n->sized ? n->w : n->iw;
}
int32_t node_h(const Node* n) {
  return n->sized ? n->h : n->ih;
}

bool g_warned_blend = false;
bool g_warned_transform = false;
bool g_warned_i8 = false;

// DIRTY_WALK: this frame's `clip` and `vis` of every node, and the areas that
// changed since the last frame drew. A hidden node's area is empty, so what its
// subtree drew is drawn over.
void walk(Node* n, int32_t px, int32_t py, const Area& clip, bool dirty) {
  dirty = dirty || n->dirty;
  const bool redraw = dirty || n->recolor;
  n->dirty = n->recolor = false;
  const int32_t ax = px + n->x;
  const int32_t ay = py + n->y;
  const int32_t w = node_w(n);
  const int32_t h = node_h(n);
  const Area area =
      n->hidden ? Area{} : intersect(clip, clamp_rect(ax, ay, w, h));
  if (n->kind == Kind::kSprite) {
    n->vis = Area{};
    if (n->src != Src::kNone && n->iw > 0 && n->ih > 0) {
      // lv_image's default LV_IMAGE_ALIGN_CENTER inside the object.
      n->ix = ax + (w / 2 - n->iw / 2);
      n->iy = ay + (h / 2 - n->ih / 2);
      n->vis = intersect(area, clamp_rect(n->ix, n->iy, n->iw, n->ih));
    }
  } else {
    n->clip = area;
    for (Node* c = n->first; c; c = c->next)
      walk(c, ax, ay, area, dirty);
    n->vis = n->kind == Kind::kFrame && n->color[3] != 0 ? area : Area{};
  }
  if (redraw || n->vis != n->drawn) {
    add_dirty(n->drawn);
    add_dirty(n->vis);
  }
  n->drawn = n->vis;
}

// lv_color_24_16_mix: B, G, R bytes over an RGB565 pixel at `mix`.
inline uint16_t mix24_16(const uint8_t* c1, uint16_t c2, uint8_t mix) {
  if (mix == 0)
    return c2;
  if (mix == 255)
    return static_cast<uint16_t>(((c1[2] & 0xF8) << 8) + ((c1[1] & 0xFC) << 3) +
                                 ((c1[0] & 0xF8) >> 3));
  const uint8_t inv = 255 - mix;
  return static_cast<uint16_t>(
      ((((c1[2] >> 3) * mix + ((c2 >> 11) & 0x1F) * inv) << 3) & 0xF800) +
      ((((c1[1] >> 2) * mix + ((c2 >> 5) & 0x3F) * inv) >> 3) & 0x07E0) +
      (((c1[0] >> 3) * mix + (c2 & 0x1F) * inv) >> 8));
}

// LV_OPA_MIX2.
inline uint8_t opa_mix(uint8_t a, uint8_t b) {
  return static_cast<uint8_t>((int32_t{a} * b) >> 8);
}

// The opacity an LVGL image of style opa `o` blends with: lv_obj_refr scales
// the layer's, then lv_obj_init_draw_image_dsc the image's 255 by it.
uint8_t draw_opa(uint8_t o) {
  if (o >= kOpaMax)
    return 255;
  return opa_mix(255, opa_mix(255, o));
}

// One row of `n` pixels of `f` over `d`: argb8888_image_blend /
// rgb888_image_blend.
void blend_row(uint16_t* d,
               const uint8_t* s,
               int32_t n,
               PixelFormat f,
               uint8_t opa) {
  if (f == kPixelARGB8888) {
    if (opa >= kOpaMax) {
      for (int32_t i = 0; i < n; ++i, s += 4)
        d[i] = mix24_16(s, d[i], s[3]);
    } else {
      for (int32_t i = 0; i < n; ++i, s += 4)
        d[i] = mix24_16(s, d[i], opa_mix(s[3], opa));
    }
  } else if (opa >= kOpaMax) {
    for (int32_t i = 0; i < n; ++i, s += 3)
      d[i] = static_cast<uint16_t>(((s[2] & 0xF8) << 8) + ((s[1] & 0xFC) << 3) +
                                   ((s[0] & 0xF8) >> 3));
  } else {
    for (int32_t i = 0; i < n; ++i, s += 3)
      d[i] = mix24_16(s, d[i], opa);
  }
}

// VIEW_SCRATCH: a view's rows are expanded here, a chunk at a time. A row of
// the panel's width in ARGB8888 is the most one call needs.
constexpr size_t kScratchBytes = 320 * 4;
alignas(4) uint8_t g_scratch[kScratchBytes];

struct Strip {
  Area r;
  const Node* cover;  // draw from here up
  uint16_t* px;
  int32_t stride;  // pixels
  uint16_t* at(int32_t x, int32_t y) const {
    return px + (y - r.y1) * stride + (x - r.x1);
  }
};

void draw_sprite(const Node* n, const Strip& s) {
  const Area r = intersect(n->vis, s.r);
  if (r.empty())
    return;
  const uint8_t opa = draw_opa(n->opa);
  if (opa <= kOpaMin)
    return;
  if (n->blend != Blend::kNormal)
    warn_once(g_warned_blend,
              "add/subtract blending is not drawn by this backend; drawing "
              "normal");
  if (n->scale_x != kScaleOne || n->scale_y != kScaleOne || n->rotation != 0)
    warn_once(g_warned_transform,
              "zoom and rotation are not drawn by this backend; drawing "
              "unscaled");
  if (n->format != kPixelARGB8888 && n->format != kPixelRGB888) {
    warn_once(g_warned_i8, "an indexed sprite buffer is not drawn");
    return;
  }
  const unsigned bpp = pixel_size(n->format);
  const int32_t sx = r.x1 - n->ix;
  const int32_t cols = r.x2 - r.x1 + 1;
  if (n->src == Src::kPixels) {
    for (int32_t y = r.y1; y <= r.y2; ++y) {
      const uint8_t* row =
          n->px + (static_cast<size_t>(y - n->iy) * n->iw + sx) * bpp;
      blend_row(s.at(r.x1, y), row, cols, n->format, opa);
    }
    return;
  }
  // A view: columns a scratch row wide at most, rows as many as the engine's
  // chunk and the scratch allow.
  const int32_t seg_max = static_cast<int32_t>(kScratchBytes / bpp);
  for (int32_t c0 = 0; c0 < cols; c0 += seg_max) {
    const int32_t seg = std::min(seg_max, cols - c0);
    const uint32_t stride = static_cast<uint32_t>(seg) * bpp;
    const int32_t chunk = std::max<int32_t>(
        1, std::min<int32_t>(view_chunk_rows(*n->view, seg, bpp),
                             static_cast<int32_t>(kScratchBytes / stride)));
    for (int32_t y = r.y1; y <= r.y2; y += chunk) {
      const int32_t rows = std::min(chunk, r.y2 - y + 1);
      view_fill(*n->view, sx + c0, sx + c0 + seg - 1, y - n->iy, rows,
                g_scratch, stride, bpp);
      for (int32_t i = 0; i < rows; ++i)
        blend_row(s.at(r.x1 + c0, y + i), g_scratch + i * stride, seg,
                  n->format, opa);
    }
  }
}

// A frame's colour, as the ARGB8888 overlay canvas of gfx_lvgl.cxx blends it.
void draw_color(const Node* n, const Strip& s) {
  const Area r = intersect(n->vis, s.r);
  if (r.empty())
    return;
  for (int32_t y = r.y1; y <= r.y2; ++y) {
    uint16_t* d = s.at(r.x1, y);
    for (int32_t x = r.x1; x <= r.x2; ++x, ++d)
      *d = mix24_16(n->color, *d, n->color[3]);
  }
}

bool contains(const Area& outer, const Area& inner) {
  return !outer.empty() && outer.x1 <= inner.x1 && outer.y1 <= inner.y1 &&
         outer.x2 >= inner.x2 && outer.y2 >= inner.y2;
}

// COVER: the last sprite in drawing order that paints every pixel of the
// strip (an untransformed RGB888 image at a covering opacity and normal
// blend). Nothing under it is drawn, which skips the expansion of the views
// beneath. LVGL draws them all (an lv_image never passes lv_obj's background
// cover check); the pixels are the same, since this sprite overwrites them.
const Node* find_cover(const Node* n, const Area& s) {
  if (n->hidden)
    return nullptr;
  if (n->kind == Kind::kSprite)
    return n->src != Src::kNone && n->format == kPixelRGB888 &&
                   n->opa >= kOpaMax && n->blend == Blend::kNormal &&
                   n->scale_x == kScaleOne && n->scale_y == kScaleOne &&
                   n->rotation == 0 && contains(n->vis, s)
               ? n
               : nullptr;
  if (!contains(n->clip, s))
    return nullptr;
  for (const Node* c = n->last; c; c = c->prev)
    if (const Node* found = find_cover(c, s))
      return found;
  return nullptr;
}

void draw_tree(const Node* n, const Strip& s, bool& on) {
  if (n->hidden)
    return;
  if (n->kind == Kind::kSprite) {
    on = on || n == s.cover;
    if (on)
      draw_sprite(n, s);
    return;
  }
  if (intersect(n->clip, s.r).empty())
    return;
  for (const Node* c = n->first; c; c = c->next)
    draw_tree(c, s, on);
  if (on && n->kind == Kind::kFrame && n->color[3] != 0)
    draw_color(n, s);
}

void draw_area(Display& d, const Area& r) {
  const int32_t w = r.x2 - r.x1 + 1;
  const int32_t rows =
      std::max<int32_t>(1, static_cast<int32_t>(d.cfg.strip_px / w));
  for (int32_t y = r.y1; y <= r.y2; y += rows) {
    Strip s;
    s.r = r;
    s.r.y1 = static_cast<int16_t>(y);
    s.r.y2 = static_cast<int16_t>(std::min<int32_t>(r.y2, y + rows - 1));
    s.px = d.cfg.strip;
    s.stride = w;
    const int32_t h = s.r.y2 - s.r.y1 + 1;
    s.cover = find_cover(&d.root, s.r);
    // The screen's own black background, under everything.
    if (!s.cover)
      std::memset(s.px, 0, static_cast<size_t>(w) * h * sizeof(uint16_t));
    bool on = !s.cover;
    draw_tree(&d.root, s, on);
    d.cfg.flush(r.x1, s.r.y1, w, h, s.px);
  }
}

}  // namespace

// ---- Display and frame ------------------------------------------------------

Node* root(Display* d) {
  return &d->root;
}

void display_size(Display* d, int32_t& w, int32_t& h) {
  w = d->cfg.width;
  h = d->cfg.height;
}

void draw_now(Display& d) {
  if (!d.drawn_once) {
    add_dirty(screen_rect(d));
    d.drawn_once = true;
  }
  walk(&d.root, 0, 0, screen_rect(d), false);
  if (d.ndirty == 0)
    return;
  DrawHold hold;
  for (int i = 0; i < d.ndirty; ++i)
    draw_area(d, d.dirty[i]);
  d.ndirty = 0;
}

void frame_draw() {
  Display* d = g_disp;
  if (!d)
    return;
  // lv_timer_handler's refresh timer: due once the period has passed since it
  // last ran.
  const uint32_t now = d->cfg.tick_ms();
  if (d->drawn_once && d->cfg.refresh_period_ms &&
      now - d->last_draw < d->cfg.refresh_period_ms)
    return;
  d->last_draw = now;
  draw_now(*d);
}

uint32_t tick_ms() {
  return g_disp ? g_disp->cfg.tick_ms() : 0;
}

void delay_ms(uint32_t ms) {
  if (g_disp)
    g_disp->cfg.delay_ms(ms);
}

bool can_snapshot() {
  return false;
}

SnapResult snapshot_take(Display*, Snapshot&) {
  return SnapResult::kFailed;
}

void snapshot_release(Snapshot& s) {
  s.impl = nullptr;
}

// ---- Nodes ------------------------------------------------------------------

Node* sprite_new(Node* parent) {
  return new_node(parent, Kind::kSprite);
}

// A frame clips to its area and holds the content layer, which is moved by
// (-ox, -oy) and, as in LVGL, clips too.
Node* viewport_new(Node* parent) {
  Node* frame = new_node(parent, Kind::kFrame);
  new_node(frame, Kind::kContent);
  return frame;
}

Node* viewport_content(Node* frame) {
  return frame->first;
}

Node* viewport_overlay(Node*, bool) {
  return nullptr;
}

bool viewport_set_color(Node* frame,
                        uint8_t b,
                        uint8_t g,
                        uint8_t r,
                        uint8_t a) {
  const uint8_t c[4] = {b, g, r, a};
  if (std::memcmp(frame->color, c, 4) != 0) {
    frame->recolor = frame->recolor || frame->color[3] != 0 || a != 0;
    std::memcpy(frame->color, c, 4);
  }
  return true;
}

void node_bind(Node* n, void* owner) {
  n->owner = owner;
}

void node_delete(Node* n) {
  if (n == (g_disp ? &g_disp->root : nullptr))
    return;
  unlink(n);
  free_subtree(n);
}

Node* node_parent(Node* n) {
  return n->parent;
}

void node_raise(Node* n) {
  Node* p = n->parent;
  if (!p || p->last == n)
    return;
  unlink(n);
  append(p, n);
  touch(n);
}

void node_reparent(Node* n, Node* parent) {
  if (n->parent == parent)
    return;
  unlink(n);
  append(parent, n);
  touch(n);
}

void node_invalidate(Node* n) {
  touch(n);
}

void node_set_pos(Node* n, int32_t x, int32_t y) {
  if (n->x == x && n->y == y)
    return;
  n->x = x;
  n->y = y;
  touch(n);
}

void node_set_x(Node* n, int32_t x) {
  node_set_pos(n, x, n->y);
}

void node_set_y(Node* n, int32_t y) {
  node_set_pos(n, n->x, y);
}

void node_set_size(Node* n, int32_t w, int32_t h) {
  if (n->sized && n->w == w && n->h == h)
    return;
  n->sized = true;
  n->w = w;
  n->h = h;
  touch(n);
}

void node_set_hidden(Node* n, bool hidden) {
  if (n->hidden == hidden)
    return;
  n->hidden = hidden;
  touch(n);
}

// ---- Sprites ----------------------------------------------------------------

void sprite_set_pixels(Node* n,
                       uint8_t* px,
                       int32_t w,
                       int32_t h,
                       PixelFormat f) {
  n->src = Src::kPixels;
  n->px = px;
  n->iw = static_cast<int16_t>(w);
  n->ih = static_cast<int16_t>(h);
  n->format = f;
  touch(n);
}

void sprite_clear(Node* n) {
  n->src = Src::kNone;
  n->px = nullptr;
  n->iw = n->ih = 0;
  touch(n);
}

void sprite_set_opacity(Node* n, uint8_t opa) {
  if (n->opa == opa)
    return;
  n->opa = opa;
  touch(n);
}

void sprite_set_scale_x(Node* n, uint32_t scale) {
  n->scale_x = static_cast<uint16_t>(std::min<uint32_t>(scale, 0xffff));
  touch(n);
}

void sprite_set_scale_y(Node* n, uint32_t scale) {
  n->scale_y = static_cast<uint16_t>(std::min<uint32_t>(scale, 0xffff));
  touch(n);
}

void sprite_set_rotation(Node* n, int32_t tenths) {
  n->rotation = static_cast<int16_t>(tenths);
  touch(n);
}

void sprite_set_pivot(Node*, int32_t, int32_t) {}

bool sprite_transformed(Node* n) {
  return n->scale_x != kScaleOne || n->scale_y != kScaleOne || n->rotation != 0;
}

void sprite_set_blend(Node* n, Blend b) {
  if (n->blend == b)
    return;
  n->blend = b;
  touch(n);
}

bool views_ready() {
  return true;
}

View* sprite_view(Node* n) {
  return n->view;
}

void sprite_attach_view(Node* n, View* v) {
  n->view = v;
}

void sprite_show_view(Node* n, View* v, PixelFormat f, int32_t w, int32_t h) {
  n->view = v;
  n->src = Src::kView;
  n->px = nullptr;
  n->iw = static_cast<int16_t>(w);
  n->ih = static_cast<int16_t>(h);
  n->format = f;
  touch(n);
}

}  // namespace gfx
}  // namespace rgss

RgssOwnDisplay* rgss_own_display_create(const RgssOwnConfig* config) {
  using rgss::gfx::Display;
  using rgss::gfx::g_disp;
  if (g_disp)
    return reinterpret_cast<RgssOwnDisplay*>(g_disp);
  if (!config || !config->strip || !config->flush || !config->tick_ms ||
      !config->delay_ms ||
      config->strip_px < static_cast<size_t>(config->width)) {
    std::fprintf(stderr,
                 "[RGSS] gfx: a display needs a strip of a row or more, "
                 "a flush and a clock\n");
    return nullptr;
  }
  Display* d = new (std::nothrow) Display();
  if (!d) {
    std::fprintf(stderr, "[RGSS] gfx: no memory for the display\n");
    return nullptr;
  }
  d->cfg = *config;
  d->root.kind = rgss::gfx::Kind::kRoot;
  d->root.sized = true;
  d->root.w = config->width;
  d->root.h = config->height;
  g_disp = d;
  return reinterpret_cast<RgssOwnDisplay*>(d);
}

void rgss_own_set_refresh_period(RgssOwnDisplay* d, uint32_t ms) {
  reinterpret_cast<rgss::gfx::Display*>(d)->cfg.refresh_period_ms = ms;
}

void rgss_own_draw_now(RgssOwnDisplay* d) {
  rgss::gfx::draw_now(*reinterpret_cast<rgss::gfx::Display*>(d));
}

extern "C" void rgss_set_display(mrb_state* M, RgssOwnDisplay* display) {
  rgss::gfx::display_attached(M,
                              reinterpret_cast<rgss::gfx::Display*>(display));
}

#endif  // RGSS_GFX_OWN
