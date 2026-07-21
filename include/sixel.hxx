#pragma once

#include <cstdint>

// Forward declarations to avoid pulling heavy headers into every includer.
struct mrb_state;
struct _lv_display_t;
typedef struct _lv_display_t lv_display_t;

// Create an LVGL display that renders each frame to the terminal using the
// DEC sixel graphics protocol instead of opening a desktop window.  This lets
// the games be played inside any sixel-capable terminal (xterm -ti vt340,
// mlterm, foot, wezterm, Windows Terminal, ...).
//
// `hor_res`/`ver_res` are the logical game resolution.  `scale` upscales the
// emitted image by an integer nearest-neighbour factor so pixel-art is legible
// in a terminal.  The created display is registered as LVGL's default display.
//
// As a side effect the controlling terminal is switched into raw mode so that
// keyboard input can be read without line buffering; it is restored
// automatically on process exit.
lv_display_t* sixel_display_create(int32_t hor_res, int32_t ver_res, int scale);

// Poll the terminal for keyboard input and forward it to the RGSS::Input
// module.  Safe to call unconditionally: it is a no-op until a sixel display
// has been created.  Meant to be invoked once per frame from Graphics.update.
void sixel_terminal_poll(mrb_state* M);
