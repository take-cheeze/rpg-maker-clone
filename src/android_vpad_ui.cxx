// Visible virtual-gamepad overlay for the Android port.
//
// src/sdl_input.cxx already maps SDL finger events onto RGSS::Input keys by
// window zone (left 40% floating D-pad, right side split into B/cancel and
// C/confirm-A) -- but zones are invisible, so nothing on screen tells a player
// the controls exist or which thumb spot does what. This file draws that same
// layout as LVGL widgets on lv_layer_top(): the layer composites above every
// game viewport (the game hangs its canvases off the active screen --
// mruby-rgss/src/lib.cxx's vp_init) and survives scene switches, since nothing
// ever cleans the top layer.
//
// The widgets are pure affordance: no click callbacks are wired and input
// still flows through sdl_input.cxx's zone logic alone, so a finger anywhere
// in a left-side zone steers exactly as before, drawn arrow or not.
//
// Press notifications arrive via rgss_vpad_overlay_key from the SDL event
// watch, which fires inside lv_timer_handler's own event pump; touching LVGL
// objects there would be re-entrant with whichever timer is doing the pump.
// So the call only queues the (key, press) pair, and an lv_timer drains the
// queue once per frame, toggling LV_STATE_PRESSED on the matching widget --
// the same push/poll shape as mruby-rgss's input_bridge.cxx: the producer
// never calls into LVGL.
//
// Android-only (CMakeLists.txt's ANDROID branch adds this source): desktop
// windows have real keyboards, and the browser build draws its keypad in HTML
// (src/shell.html).

#include <SDL2/SDL.h>
#include <lvgl.h>

#include <cmath>

// mruby-rgss's game root (src/lib.cxx): the container every game object hangs
// off, which this file centres in the display's letterbox.
extern "C" lv_obj_t* rgss_game_root_obj(lv_display_t* disp);

namespace {

// RGSS::Input key ids drawn here. Mirrors enum RgssKey in src/sdl_input.cxx
// (UP=0 DOWN=1 LEFT=2 RIGHT=3 B=5 C=6); the zones never emit anything else.
enum {
  KEY_UP = 0,
  KEY_DOWN = 1,
  KEY_LEFT = 2,
  KEY_RIGHT = 3,
  KEY_B = 5,
  KEY_C = 6
};

constexpr int QUEUE_MAX = 32;

struct VisualChange {
  int key;
  bool press;
};

// Filled by rgss_vpad_overlay_key (SDL event-watch context), drained once per
// frame by visual_timer_cb. Both run on the main thread, so no locking. A
// flood overwrites the oldest still-unapplied change rather than dropping the
// newest: what matters for a held-key highlight is the latest state per key.
VisualChange g_queue[QUEUE_MAX] = {};
int g_queue_head = 0;  // next slot to write
int g_queue_count = 0;

lv_obj_t* g_dpad[4] = {};  // indexed by KEY_UP..KEY_RIGHT
lv_obj_t* g_button_b = nullptr;
lv_obj_t* g_button_c = nullptr;

lv_obj_t* widget_for_key(int key) {
  if (key >= KEY_UP && key <= KEY_RIGHT)
    return g_dpad[key];
  if (key == KEY_B)
    return g_button_b;
  if (key == KEY_C)
    return g_button_c;
  return nullptr;
}

void visual_timer_cb(lv_timer_t* /*timer*/) {
  while (g_queue_count > 0) {
    const int idx = (g_queue_head - g_queue_count + QUEUE_MAX) % QUEUE_MAX;
    --g_queue_count;
    lv_obj_t* obj = widget_for_key(g_queue[idx].key);
    if (!obj)
      continue;
    if (g_queue[idx].press)
      lv_obj_add_state(obj, LV_STATE_PRESSED);
    else
      lv_obj_remove_state(obj, LV_STATE_PRESSED);
  }
}

// One translucent pad button: a circle with the Sapphire Chip logo's cream
// border/label on near-black, inverting while pressed. Styles live directly on
// the object so no active theme leaks in. text_color is an inherited property,
// so the child label picks up both states from the button without any styling
// of its own beyond centering. Built from a plain base object rather than the
// button widget: this project ships LV_USE_BUTTON 0 (the game draws everything
// as canvases), and these affordances have no callbacks for the widget's click
// machinery to drive anyway.
lv_obj_t* make_pad_button(lv_obj_t* parent, const char* label, int32_t size) {
  lv_obj_t* btn = lv_obj_create(parent);
  lv_obj_remove_style_all(btn);
  lv_obj_set_size(btn, size, size);
  lv_obj_set_style_radius(btn, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_color(btn, lv_color_hex(0x10141f), 0);
  lv_obj_set_style_bg_opa(btn, LV_OPA_40, 0);
  lv_obj_set_style_border_color(btn, lv_color_hex(0xe8e4d8), 0);
  lv_obj_set_style_border_width(btn, 2, 0);
  lv_obj_set_style_border_opa(btn, LV_OPA_70, 0);
  lv_obj_set_style_text_color(btn, lv_color_hex(0xe8e4d8), 0);
  lv_obj_set_style_shadow_width(btn, 0, 0);
  lv_obj_set_style_bg_color(btn, lv_color_hex(0xe8e4d8), LV_STATE_PRESSED);
  lv_obj_set_style_bg_opa(btn, LV_OPA_90, LV_STATE_PRESSED);
  lv_obj_set_style_text_color(btn, lv_color_hex(0x10141f), LV_STATE_PRESSED);

  lv_obj_t* lab = lv_label_create(btn);
  lv_label_set_text(lab, label);
  lv_obj_center(lab);
  return btn;
}

}  // namespace

namespace {

// The game's own resolution (src/main.cxx's FLAGS_width/FLAGS_height), which
// the game root is sized to; everything else on the (phone-shaped) display is
// letterbox to centre it into.
int32_t g_game_w = 0;
int32_t g_game_h = 0;

// The SDL window arrives phone-shaped and LVGL's SDL driver answers by
// resizing the display to window/zoom (lv_sdl_window.c's RESIZED case), while
// the game keeps its 4:3 picture at (0,0) -- top-left, black bands right and
// bottom. Centre mruby-rgss's game root (the parent of every game object) in
// the display so the picture sits in the middle and the pad's corners get the
// letterbox. Called at init and on every later resolution change (rotation).
void center_game_root(void) {
  lv_display_t* disp = lv_display_get_default();
  const int32_t hor = lv_display_get_horizontal_resolution(disp);
  const int32_t ver = lv_display_get_vertical_resolution(disp);
  lv_obj_t* root = rgss_game_root_obj(disp);
  lv_obj_set_pos(root, (hor - g_game_w) / 2 > 0 ? (hor - g_game_w) / 2 : 0,
                 (ver - g_game_h) / 2 > 0 ? (ver - g_game_h) / 2 : 0);
}

// The SDL surface arrives phone-shaped and fixed (SDLActivity owns its size),
// and LVGL's SDL driver answers the resize by setting the display to
// window/zoom -- with main.cxx's static zoom (2 for the 320x240 makers) that
// leaves a 1198x679 surface rendering at 599x339: LVGL software-rasters 2.8x
// the game's own pixels and uploads them, only for the GPU to stretch them
// again on the way out. Measured on-device (C330) that render+present is
// ~16ms of a ~45ms map-scene frame -- 22fps where the game logic itself would
// keep up. Fit the zoom so the *display height* equals the game's instead:
// the game picture then rasters 1:1, the letterbox shrinks to side bands, and
// the GPU does the upscale (non-integer, but nearest-neighbour -- the same
// look the browser build asks for with image-rendering: pixelated). Runs on
// every resolution change; the guards make it a no-op once fitted and break
// the re-entry loop (set_zoom fires this event again).
void fit_zoom_to_game(void) {
  lv_display_t* disp = lv_display_get_default();
  int w = 0, h = 0;
  SDL_GetWindowSize(lv_sdl_window_get_window(disp), &w, &h);
  // Before Android's surface arrives the window still reads as the size
  // lv_sdl_window_create asked for -- the game's own resolution, which
  // main.cxx's zoom already fits. Fitting here would divide by a zoom
  // measured against a window that is about to be replaced.
  if (w <= 0 || h <= 0 || (w == g_game_w && h == g_game_h))
    return;
  const float want = static_cast<float>(h) / static_cast<float>(g_game_h);
  if (std::fabs(want - lv_sdl_window_get_zoom(disp)) < 0.01f)
    return;
  // Re-enters this callback once (zoom now matches, second pass returns);
  // the set_resolution below then re-fires it for the centring pass.
  lv_sdl_window_set_zoom(disp, want);
  lv_display_set_resolution(disp, static_cast<int32_t>(std::lround(w / want)),
                            static_cast<int32_t>(std::lround(h / want)));
}

void display_event_cb(lv_event_t* e) {
  if (lv_event_get_code(e) == LV_EVENT_RESOLUTION_CHANGED) {
    fit_zoom_to_game();
    center_game_root();
  }
}

}  // namespace

// Queue one pad-driven key transition (called from the SDL event watch in
// src/sdl_input.cxx; see the file comment for why this only queues).
extern "C" void rgss_vpad_overlay_key(int key, bool press) {
  g_queue[g_queue_head] = {key, press};
  g_queue_head = (g_queue_head + 1) % QUEUE_MAX;
  if (g_queue_count < QUEUE_MAX)
    ++g_queue_count;
}

// Build the pad on lv_layer_top() and centre the game picture. Call once,
// after the LVGL display exists (src/main.cxx creates it before installing
// the input watch), passing the game's own resolution.
extern "C" void rgss_vpad_overlay_init(int game_w, int game_h) {
  g_game_w = game_w;
  g_game_h = game_h;
  lv_display_t* disp = lv_display_get_default();
  const int32_t hor = lv_display_get_horizontal_resolution(disp);
  const int32_t ver = lv_display_get_vertical_resolution(disp);
  // Scale everything off the smaller edge so the pad keeps thumb-sized
  // proportions at whatever resolution a maker runs (320x240 RPG2000, MV's
  // larger canvases); the window zoom scales it along with the game picture.
  const int32_t unit = hor < ver ? hor : ver;
  const int32_t cell = unit / 6;
  const int32_t margin = cell / 2;
  const int32_t confirm = unit / 4;
  const int32_t cancel = unit / 5;

  lv_obj_t* layer = lv_layer_top();
  lv_obj_remove_flag(layer, LV_OBJ_FLAG_SCROLLABLE);

  // D-pad cross, bottom-left: four arrow buttons in a plus. The container
  // carries no CLICKABLE flag, so it never swallows a tap aimed between the
  // arrows -- only the arrows themselves are hit targets, and even they have
  // no callbacks; the zone logic underneath owns input.
  lv_obj_t* dpad = lv_obj_create(layer);
  lv_obj_remove_style_all(dpad);
  lv_obj_remove_flag(dpad, static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_SCROLLABLE |
                                                      LV_OBJ_FLAG_CLICKABLE));
  lv_obj_set_size(dpad, cell * 3, cell * 3);
  lv_obj_align(dpad, LV_ALIGN_BOTTOM_LEFT, margin, -margin);
  struct Arrow {
    int key;
    const char* glyph;
    int32_t x, y;
  };
  static const Arrow kArrows[] = {
      {KEY_UP, LV_SYMBOL_UP, cell, 0},
      {KEY_LEFT, LV_SYMBOL_LEFT, 0, cell},
      {KEY_RIGHT, LV_SYMBOL_RIGHT, cell * 2, cell},
      {KEY_DOWN, LV_SYMBOL_DOWN, cell, cell * 2},
  };
  for (const Arrow& a : kArrows) {
    g_dpad[a.key] = make_pad_button(dpad, a.glyph, cell);
    lv_obj_set_pos(g_dpad[a.key], a.x, a.y);
  }

  // Cancel/confirm cluster, right side: C (confirm/A) big in the bottom-right
  // corner, B (cancel) directly above it. B is *not* simply stacked next to C:
  // sdl_input.cxx splits the right zone into B/cancel and C/confirm at window
  // mid-height, so B's centre has to stay in the upper half of the *window*
  // for its label to tell the truth. 40% of the display height leaves margin
  // for a status-bar inset above the surface (the display is the SDL surface
  // divided by the window zoom, so display fraction == window fraction); the
  // gap this opens above C is the price of honest labels.
  g_button_c = make_pad_button(layer, "C", confirm);
  lv_obj_align(g_button_c, LV_ALIGN_BOTTOM_RIGHT, -margin, -margin);
  g_button_b = make_pad_button(layer, "B", cancel);
  lv_obj_align(g_button_b, LV_ALIGN_TOP_RIGHT,
               -(margin + confirm / 2 - cancel / 2), ver * 2 / 5 - cancel / 2);

  // Drain once per frame-ish; 30 ms sits under the game's own 60 fps pacing,
  // so a press highlight never lags a visible frame behind its input.
  lv_timer_create(visual_timer_cb, 30, nullptr);

  // Centre the game now and again whenever the display resizes (the surface
  // size lands as an SDL RESIZED event shortly after boot, and rotation can
  // change it again later). The zoom fit runs first so the centring sees the
  // final resolution.
  fit_zoom_to_game();
  center_game_root();
  lv_display_add_event_cb(disp, display_event_cb, LV_EVENT_RESOLUTION_CHANGED,
                          nullptr);
}
