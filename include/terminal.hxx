#pragma once

#include <cstddef>
#include <cstdint>

// Forward declarations to avoid pulling heavy headers into every includer.
struct mrb_state;
struct _lv_display_t;
typedef struct _lv_display_t lv_display_t;

// A per-protocol frame encoder.  It is handed one finished frame as an RGB565
// buffer at the logical game resolution (`w`x`h`) plus the integer upscale
// factor `scale`, and is responsible for turning it into a terminal byte stream
// and emitting it with `terminal_write`.  The sixel and iTerm2 backends differ
// only in this function; everything else (raw mode, input, timing, the LVGL
// display/buffer wiring) is shared.
using terminal_encode_fn = void (*)(int w, int h, int scale, const uint16_t* pix);

// Create a windowless LVGL display that renders each frame to the controlling
// terminal via `encode`, instead of opening a desktop window.
//
// `hor_res`/`ver_res` are the logical game resolution; `scale` upscales the
// emitted image by an integer nearest-neighbour factor so pixel-art is legible
// in a terminal.  The created display is registered as LVGL's default display.
//
// As a side effect the controlling terminal is switched into raw mode (so
// keyboard input can be read without line buffering) and into the alternate
// screen buffer (so the game does not overwrite the user's shell history), and a
// monotonic tick/delay source is installed so LVGL runs without SDL.  The
// terminal state is restored automatically on process exit and on fatal
// signals.
lv_display_t* terminal_display_create(int32_t hor_res,
                                      int32_t ver_res,
                                      int scale,
                                      terminal_encode_fn encode);

// Poll the terminal for keyboard input and forward it to the RGSS::Input
// module.  Safe to call unconditionally: it is a no-op until a terminal display
// has been created.  Meant to be invoked once per frame from Graphics.update.
void terminal_poll(mrb_state* M);

// Write raw bytes to the controlling terminal, handling partial writes and
// EINTR.  Meant for encoders assembling a frame.
void terminal_write(const char* p, size_t n);
