// SDL keyboard -> RGSS::Input bridge (mruby side).
//
// The SDL window backend lives in the executable, which is the only place with
// SDL headers on its include path (the mruby-rgss gem is also built for the
// terminal-only and emscripten variants and must not depend on SDL directly).
// That executable installs an SDL event watch which translates SDL keysyms into
// the integer RGSS::Input key ids (see mruby-rgss/mrblib/lib.rb) and hands them
// here via rgss_sdl_input_push, without touching the mruby VM.
//
// rgss_sdl_poll then drains the buffered transitions into RGSS::Input once per
// frame from Graphics.update, on the same thread that runs the interpreter.
// This mirrors rgss_terminal_poll: SDL delivers real key-up events, so presses
// and releases map straight onto RGSS::Input.press / RGSS::Input.release with
// no hold-timer emulation.

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/value.h>

#include <vector>

namespace {

struct PendingKey {
  int key;
  bool press;
};

// Filled by rgss_sdl_input_push (SDL event-watch context), drained by
// rgss_sdl_poll (interpreter frame). Both run on the main thread, so no locking
// is needed. Empty unless the SDL backend is active, which keeps this a cheap
// no-op under the terminal backends.
std::vector<PendingKey> g_pending;

}  // namespace

// Called from the executable's SDL event watch with an already-translated RGSS
// key id (>= 0) and whether it was pressed or released.
extern "C" void rgss_sdl_input_push(int key, bool press) {
  g_pending.push_back({key, press});
}

// --- mouse ------------------------------------------------------------------
// The latest pointer position (in game/window pixels — the SDL window backend
// renders the game 1:1 at MV's resolution, which is the only maker that reads
// the mouse) and left-button state. Written by the SDL event watch, read on the
// interpreter thread. Only current state is kept — consumers (e.g. MV's
// TouchInput) derive their own trigger/press timing — so no queue is needed.
namespace {
int g_mouse_x = 0;
int g_mouse_y = 0;
bool g_mouse_pressed = false;
}  // namespace

// Called from the executable's SDL event watch for mouse motion/button events.
extern "C" void rgss_sdl_mouse_push(int x, int y, bool pressed) {
  g_mouse_x = x;
  g_mouse_y = y;
  g_mouse_pressed = pressed;
}

extern "C" int rgss_mouse_x(void) {
  return g_mouse_x;
}
extern "C" int rgss_mouse_y(void) {
  return g_mouse_y;
}
extern "C" int rgss_mouse_pressed(void) {
  return g_mouse_pressed ? 1 : 0;
}

// Drains buffered SDL key transitions into RGSS::Input. Called every frame from
// Graphics.update, next to rgss_terminal_poll.
extern "C" void rgss_sdl_poll(mrb_state* M) {
  if (g_pending.empty())
    return;

  RClass* rgss = mrb_module_get(M, "RGSS");
  if (!rgss) {
    g_pending.clear();
    return;
  }
  RClass* input = mrb_module_get_under(M, rgss, "Input");
  if (!input) {
    g_pending.clear();
    return;
  }

  // Swap out the queue first so a re-entrant push (there is none today, but the
  // mruby calls below run arbitrary Ruby) cannot invalidate the iterator or be
  // dropped.
  std::vector<PendingKey> pending;
  pending.swap(g_pending);
  for (const PendingKey& e : pending)
    mrb_funcall(M, mrb_obj_value(input), e.press ? "press" : "release", 1,
                mrb_fixnum_value(e.key));
}
