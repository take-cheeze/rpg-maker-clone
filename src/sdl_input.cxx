// SDL keyboard capture for the desktop / browser (SDL) window backend.
//
// LVGL's SDL driver drains the whole SDL event queue itself inside
// lv_timer_handler (see 3rd/lvgl/src/drivers/sdl/lv_sdl_window.c), so a second
// SDL_PollEvent loop here would race it and steal events. Instead we register
// an SDL event *watch*, which observes every event as it is pumped without
// removing it from the queue, leaving LVGL's own handling untouched.
//
// The watch only translates keysyms to RGSS::Input key ids and buffers them via
// rgss_sdl_input_push (defined in the mruby-rgss gem); the buffered transitions
// are applied to RGSS::Input from rgss_sdl_poll during Graphics.update. Keeping
// the SDL specifics here means the gem never needs SDL on its include path.

#include <SDL2/SDL.h>

// Buffer sinks implemented in mruby-rgss/src/input_bridge.cxx.
extern "C" void rgss_sdl_input_push(int key, bool press);
extern "C" void rgss_sdl_mouse_push(int x, int y, bool pressed);

namespace {

#ifdef __ANDROID__
// The Android visible-pad overlay (src/android_vpad_ui.cxx) mirrors every
// *pad-driven* key transition as a pressed look on its widgets. Keyboard
// presses deliberately skip this: the pad highlights what the thumbs do.
extern "C" void rgss_vpad_overlay_key(int key, bool press);
#endif

void vpad_notify(int key, bool press) {
#ifdef __ANDROID__
  rgss_vpad_overlay_key(key, press);
#else
  (void)key;
  (void)press;
#endif
}

// RGSS::Input key ids. Mirrors the constants in mruby-rgss/mrblib/lib.rb.
enum RgssKey {
  KEY_UP = 0,
  KEY_DOWN = 1,
  KEY_LEFT = 2,
  KEY_RIGHT = 3,
  KEY_A = 4,
  KEY_B = 5,
  KEY_C = 6,
  KEY_X = 7,
  KEY_Y = 8,
  KEY_Z = 9,
  KEY_L = 10,
  KEY_R = 11,
  KEY_SHIFT = 12,
  KEY_CTRL = 13,
  KEY_ALT = 14,
  KEY_F5 = 15,
  KEY_F6 = 16,
  KEY_F7 = 17,
  KEY_F8 = 18,
  KEY_F9 = 19,
  KEY_F12 = 20,
  // RPG2003 Key Input Processing's Numbers/Operators groups (mruby-rgss's
  // RGSS::Input::N0..PERIOD). Real key backing for these lives only in this
  // SDL backend today -- see the comment on those constants in
  // mruby-rgss/mrblib/lib.rb.
  KEY_N0 = 21,
  KEY_N1 = 22,
  KEY_N2 = 23,
  KEY_N3 = 24,
  KEY_N4 = 25,
  KEY_N5 = 26,
  KEY_N6 = 27,
  KEY_N7 = 28,
  KEY_N8 = 29,
  KEY_N9 = 30,
  KEY_PLUS = 31,
  KEY_MINUS = 32,
  KEY_MULTIPLY = 33,
  KEY_DIVIDE = 34,
  KEY_PERIOD = 35,
};

// Map an SDL keysym to an RGSS::Input key id, or -1 when the key is unbound.
//
// Confirm (C), cancel (B) and A follow the terminal backend's choices so both
// window and terminal play the same: Z/Enter/Space confirm, X/Esc cancel, C is
// the A button. The remaining letters, page keys, modifiers and function keys
// follow RPG Maker XP's default keyboard layout.
int map_key(SDL_Keycode k) {
  switch (k) {
    case SDLK_UP:
      return KEY_UP;
    case SDLK_DOWN:
      return KEY_DOWN;
    case SDLK_LEFT:
      return KEY_LEFT;
    case SDLK_RIGHT:
      return KEY_RIGHT;
    case SDLK_z:
    case SDLK_RETURN:
    case SDLK_KP_ENTER:
    case SDLK_SPACE:
      return KEY_C;
    case SDLK_x:
    case SDLK_ESCAPE:
      return KEY_B;
    case SDLK_c:
      return KEY_A;
    case SDLK_a:
      return KEY_X;
    case SDLK_s:
      return KEY_Y;
    case SDLK_d:
      return KEY_Z;
    case SDLK_q:
    case SDLK_PAGEUP:
      return KEY_L;
    case SDLK_w:
    case SDLK_PAGEDOWN:
      return KEY_R;
    case SDLK_LSHIFT:
    case SDLK_RSHIFT:
      return KEY_SHIFT;
    case SDLK_LCTRL:
    case SDLK_RCTRL:
      return KEY_CTRL;
    case SDLK_LALT:
    case SDLK_RALT:
      return KEY_ALT;
    case SDLK_F5:
      return KEY_F5;
    case SDLK_F6:
      return KEY_F6;
    case SDLK_F7:
      return KEY_F7;
    case SDLK_F8:
      return KEY_F8;
    case SDLK_F9:
      return KEY_F9;
    case SDLK_F12:
      return KEY_F12;
    // Numbers: both the main-row digit keys and the numeric keypad produce
    // the same digit (real RPG_RT accepts either), so both feed the
    // same RGSS::Input id.
    case SDLK_0:
    case SDLK_KP_0:
      return KEY_N0;
    case SDLK_1:
    case SDLK_KP_1:
      return KEY_N1;
    case SDLK_2:
    case SDLK_KP_2:
      return KEY_N2;
    case SDLK_3:
    case SDLK_KP_3:
      return KEY_N3;
    case SDLK_4:
    case SDLK_KP_4:
      return KEY_N4;
    case SDLK_5:
    case SDLK_KP_5:
      return KEY_N5;
    case SDLK_6:
    case SDLK_KP_6:
      return KEY_N6;
    case SDLK_7:
    case SDLK_KP_7:
      return KEY_N7;
    case SDLK_8:
    case SDLK_KP_8:
      return KEY_N8;
    case SDLK_9:
    case SDLK_KP_9:
      return KEY_N9;
    // Operators: the numpad has a dedicated key for all five; the main
    // keyboard row only has unshifted "-", "/" and "." (a bare SDL keycode
    // switch can't tell a shifted "+"/"*" chord from the unshifted digit
    // underneath it, so PLUS/MULTIPLY are numpad-only here).
    case SDLK_KP_PLUS:
      return KEY_PLUS;
    case SDLK_MINUS:
    case SDLK_KP_MINUS:
      return KEY_MINUS;
    case SDLK_KP_MULTIPLY:
      return KEY_MULTIPLY;
    case SDLK_SLASH:
    case SDLK_KP_DIVIDE:
      return KEY_DIVIDE;
    case SDLK_PERIOD:
    case SDLK_KP_PERIOD:
      return KEY_PERIOD;
    default:
      return -1;
  }
}

// Virtual gamepad: SDL touch events mapped to RGSS keys by window zone, so a
// phone or tablet plays without attached hardware. The left 40% of the window
// is a *floating* D-pad -- the direction set is read from each drag's offset
// against its own touch-down anchor, so no exact spot has to be hit; the right
// half splits into B (cancel, upper) and C (confirm/A, lower), and the middle
// band is dead so a resting thumb triggers nothing. Each finger keeps its own
// role and held-key set, so steering with one thumb while tapping menus with
// the other works.
constexpr float VPAD_DPAD_MAX_X = 0.4f;
constexpr float VPAD_BUTTON_MIN_X = 0.6f;
constexpr float VPAD_CONFIRM_MIN_Y = 0.5f;
constexpr float VPAD_DEAD_ZONE = 0.04f;

enum VpadRole { VPAD_NONE, VPAD_DPAD, VPAD_CANCEL, VPAD_CONFIRM };

struct VpadFinger {
  SDL_FingerID id;
  float anchor_x, anchor_y;
  VpadRole role;
  int held[2];
  int held_count;
};

VpadFinger vpad_fingers[8] = {};
int vpad_finger_total = 0;

VpadFinger* vpad_finger_find(SDL_FingerID id) {
  for (int i = 0; i < vpad_finger_total; ++i)
    if (vpad_fingers[i].id == id)
      return &vpad_fingers[i];
  return nullptr;
}

void vpad_keys_sync(VpadFinger& f, const int* want, int want_count) {
  for (int i = 0; i < f.held_count;) {
    bool still = false;
    for (int j = 0; j < want_count && !still; ++j)
      still = f.held[i] == want[j];
    if (!still) {
      rgss_sdl_input_push(f.held[i], false);
      vpad_notify(f.held[i], false);
      f.held[i--] = f.held[--f.held_count];
      continue;
    }
    ++i;
  }
  for (int i = 0; i < want_count; ++i) {
    bool already = false;
    for (int j = 0; j < f.held_count && !already; ++j)
      already = want[i] == f.held[j];
    if (!already)
      rgss_sdl_input_push(want[i], true), vpad_notify(want[i], true),
          f.held[f.held_count++] = want[i];
  }
}

void vpad_down(const SDL_TouchFingerEvent& e) {
  VpadRole role = VPAD_NONE;
  if (e.x < VPAD_DPAD_MAX_X)
    role = VPAD_DPAD;
  else if (e.x > VPAD_BUTTON_MIN_X)
    role = e.y > VPAD_CONFIRM_MIN_Y ? VPAD_CONFIRM : VPAD_CANCEL;
  if (role == VPAD_NONE || vpad_finger_find(e.fingerId))
    return;
  if (vpad_finger_total >= 8)
    return;
  VpadFinger& f = vpad_fingers[vpad_finger_total++];
  f.id = e.fingerId;
  f.anchor_x = e.x;
  f.anchor_y = e.y;
  f.role = role;
  f.held_count = 0;
  if (role == VPAD_CONFIRM)
    vpad_keys_sync(f, (const int[]){KEY_C}, 1);
  else if (role == VPAD_CANCEL)
    vpad_keys_sync(f, (const int[]){KEY_B}, 1);
}

void vpad_move(const SDL_TouchFingerEvent& e) {
  VpadFinger* f = vpad_finger_find(e.fingerId);
  if (!f || f->role != VPAD_DPAD)
    return;
  const float dx = e.x - f->anchor_x;
  const float dy = e.y - f->anchor_y;
  int want[2], want_count = 0;
  if (dy < -VPAD_DEAD_ZONE)
    want[want_count++] = KEY_UP;
  else if (dy > VPAD_DEAD_ZONE)
    want[want_count++] = KEY_DOWN;
  if (dx < -VPAD_DEAD_ZONE)
    want[want_count++] = KEY_LEFT;
  else if (dx > VPAD_DEAD_ZONE)
    want[want_count++] = KEY_RIGHT;
  vpad_keys_sync(*f, want, want_count);
}

void vpad_up(const SDL_TouchFingerEvent& e) {
  for (int i = 0; i < vpad_finger_total; ++i) {
    if (vpad_fingers[i].id != e.fingerId)
      continue;
    VpadFinger& f = vpad_fingers[i];
    for (int k = 0; k < f.held_count; ++k) {
      rgss_sdl_input_push(f.held[k], false);
      vpad_notify(f.held[k], false);
    }
    vpad_fingers[i] = vpad_fingers[--vpad_finger_total];
    return;
  }
}

int SDLCALL event_watch(void* /*user*/, SDL_Event* event) {
  int key = -1;
  bool press = false;
  switch (event->type) {
    case SDL_KEYDOWN:
      // Ignore auto-repeat: RGSS::Input derives its own repeat timing from the
      // held state, so only the initial press should re-trigger.
      if (event->key.repeat)
        return 0;
      key = map_key(event->key.keysym.sym);
      press = true;
      break;
    case SDL_KEYUP:
      key = map_key(event->key.keysym.sym);
      press = false;
      break;
    // Pointer -> RGSS mouse state (MV's TouchInput reads it). Coordinates are
    // window pixels; the SDL backend renders MV 1:1, so they are canvas pixels.
    case SDL_FINGERDOWN:
      vpad_down(event->tfinger);
      return 0;
    case SDL_FINGERMOTION:
      vpad_move(event->tfinger);
      return 0;
    case SDL_FINGERUP:
      vpad_up(event->tfinger);
      return 0;
    case SDL_MOUSEMOTION:
      rgss_sdl_mouse_push(event->motion.x, event->motion.y,
                          (event->motion.state & SDL_BUTTON_LMASK) != 0);
      return 0;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:
      if (event->button.button == SDL_BUTTON_LEFT)
        rgss_sdl_mouse_push(event->button.x, event->button.y,
                            event->type == SDL_MOUSEBUTTONDOWN);
      return 0;
    default:
      return 0;
  }
  if (key >= 0)
    rgss_sdl_input_push(key, press);
  return 0;  // ignored for watchers
}

}  // namespace

// Install the SDL keyboard watch. Call once, after the SDL window (and thus
// SDL) has been initialised.
extern "C" void rgss_sdl_input_init(void) {
  SDL_AddEventWatch(event_watch, nullptr);
}
