#pragma once

#include <cstdint>

// Forward declaration to avoid pulling heavy headers into every includer.
struct _lv_display_t;
typedef struct _lv_display_t lv_display_t;

// Create an LVGL display that renders each frame to the terminal using iTerm2's
// inline-image protocol (the OSC 1337 "File=" sequence) instead of opening a
// desktop window.  Each frame is PNG-encoded and emitted base64-encoded, so
// this works on any terminal that understands the protocol -- iTerm2, WezTerm,
// and, unlike sixel/kitty, VS Code's integrated terminal (xterm.js image
// addon).
//
// `hor_res`/`ver_res` are the logical game resolution.  `scale` upscales the
// emitted image by an integer nearest-neighbour factor so pixel-art is legible
// in a terminal.  The created display is registered as LVGL's default display.
//
// The shared terminal backend (see terminal.hxx) also puts the controlling
// terminal into raw mode and the alternate screen buffer, restored on exit; use
// terminal_poll() to forward keyboard input to RGSS::Input.
lv_display_t* iterm_display_create(int32_t hor_res, int32_t ver_res, int scale);
