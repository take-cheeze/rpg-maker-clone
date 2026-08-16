// Wio Terminal buttons -> RGSS::Input bridge (mruby side).
//
// This is the mruby half of the Wio input path, mirroring input_bridge.cxx for
// SDL: the platform HAL (wio.cxx) scans the GPIOs into a bitmask, and here we
// diff it against the previous frame and drive RGSS::Input.press / .release on
// the edges. Unlike the terminal backend, the GPIOs give a real "released"
// level, so no hold-timer emulation is needed -- presses and releases map
// straight across, as in the SDL path.
//
// rgss_wio_poll is called once per frame from Graphics.update (gfx_update in
// lib.cxx), next to rgss_sdl_poll / rgss_terminal_poll. Compiled only for the
// Wio firmware (WIO_TERMINAL); an empty file otherwise.

#ifdef WIO_TERMINAL

#include "wio.hxx"

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/value.h>

namespace {

// Button state applied to RGSS::Input on the previous poll, so only transitions
// are forwarded.
uint64_t g_prev = 0;

void send_key(mrb_state* M, int key, bool press) {
  RClass* rgss = mrb_module_get(M, "RGSS");
  if (!rgss)
    return;
  RClass* input = mrb_module_get_under(M, rgss, "Input");
  if (!input)
    return;
  mrb_funcall(M, mrb_obj_value(input), press ? "press" : "release", 1,
              mrb_fixnum_value(key));
}

}  // namespace

extern "C" void rgss_wio_poll(mrb_state* M) {
  const uint64_t cur = wio_input_scan();
  const uint64_t changed = cur ^ g_prev;
  if (changed) {
    for (int key = 0; key < WIO_INPUT_KEY_COUNT; ++key) {
      const uint64_t bit = 1ull << key;
      if (changed & bit)
        send_key(M, key, (cur & bit) != 0);
    }
    g_prev = cur;
  }
}

#endif  // WIO_TERMINAL
