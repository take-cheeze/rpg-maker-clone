// Wio Terminal (Seeed, ATSAMD51) hardware backend for the RGSS runtime.
//
// This is the platform half of the Wio port: it stands up an LVGL display over
// the board's 320x240 ILI9341 SPI LCD, installs a millis()/delay() tick source
// (LVGL needs one without SDL, exactly as the terminal backend does), and scans
// the three top buttons and the 5-way switch into a bitmask.
//
// It deliberately knows nothing about mruby so it can be compiled for a
// board-bring-up firmware without the interpreter (see app/wio). The mruby side
// -- translating the button bitmask into RGSS::Input press/release events -- is
// the separate wio_input_bridge.cxx, mirroring the sdl_input.cxx (platform) /
// input_bridge.cxx (mruby) split used by the SDL backend.
//
// The whole translation unit is compiled only when WIO_TERMINAL is defined, so
// the desktop/wasm builds (which glob every mruby-rgss/src/*.cxx into
// libmruby.a) see an empty file.

#pragma once

#include <cstdint>

#include <lvgl.h>

// Bit positions in the wio_input_scan() bitmask. They match the RGSS::Input key
// ids (mruby-rgss/mrblib/lib.rb): bit (1u << id) is set while that key is held.
enum WioKey {
  WIO_INPUT_UP = 0,
  WIO_INPUT_DOWN = 1,
  WIO_INPUT_LEFT = 2,
  WIO_INPUT_RIGHT = 3,
  WIO_INPUT_A = 4,
  WIO_INPUT_B = 5,
  WIO_INPUT_C = 6,
  WIO_INPUT_KEY_COUNT = 7,
};

// Create the LVGL display bound to the board's LCD (RGB565, partial render mode
// with a small draw buffer -- a full framebuffer would nearly exhaust SRAM).
// Also installs the LVGL tick/delay source. Returns the display, or nullptr on
// failure.
lv_display_t* wio_display_create(int32_t hor_res, int32_t ver_res);

// Configure the button / 5-way switch GPIOs (INPUT_PULLUP, active low). Call
// once from setup() before scanning.
void wio_input_init(void);

// Read the current button state as a bitmask of (1u << WioKey). A set bit means
// the key is currently held.
uint32_t wio_input_scan(void);
