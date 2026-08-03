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
    default:
      return -1;
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
