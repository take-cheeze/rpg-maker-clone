// On-screen keypad bridge for the Emscripten (browser) build.
//
// The generated page's shell (src/shell.html) draws <button> elements for the
// game's keys. Their pointer handlers call the exported rgss_wasm_key below,
// which feeds the very same input buffer the SDL keyboard watch uses
// (rgss_sdl_input_push in mruby-rgss/src/input_bridge.cxx). rgss_sdl_poll then
// drains it into RGSS::Input during Graphics.update, so a tapped button and a
// pressed key are indistinguishable to the game -- including RGSS::Input's own
// trigger/repeat timing, since a held button emits one press and one release
// just like a physical key.
//
// This lives outside src/sdl_input.cxx on purpose: that file pulls in the SDL
// headers and is about keysym translation, whereas this is a browser-only shim
// with no SDL dependency.

#include <emscripten.h>

// Buffer sink implemented in mruby-rgss/src/input_bridge.cxx (shared with the
// SDL keyboard watch).
extern "C" void rgss_sdl_input_push(int key, bool press);

// Exported to JS as Module._rgss_wasm_key. `key` is an RGSS::Input key id (see
// the enum in src/sdl_input.cxx and the constants in mruby-rgss/mrblib/lib.rb);
// `press` is non-zero for a press and zero for a release. Ids outside the known
// range are ignored so a malformed call from the page can never inject a bogus
// key into the buffer.
extern "C" EMSCRIPTEN_KEEPALIVE void rgss_wasm_key(int key, int press) {
  // 0..19 spans UP..F9; keep in sync with enum RgssKey in src/sdl_input.cxx.
  if (key < 0 || key > 19)
    return;
  rgss_sdl_input_push(key, press != 0);
}
