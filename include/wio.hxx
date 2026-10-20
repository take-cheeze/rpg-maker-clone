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
// ids (mruby-rgss/mrblib/lib.rb): bit (1ull << id) is set while that key is
// held. The mask is a uint64_t so it can carry the RPG2003 Numbers/Operators
// ids (21..35). The stock Wio Terminal's three top buttons plus its 5-way
// switch (four directions + centre press) are exactly seven signals and they
// are all already assigned above, so there is no free pin to bind the
// Numbers/Operators ids -- they remain unbound here, the same way F5-F12 are.
// The slots are reserved only so a custom board that wires more buttons can
// feed them without changing the layout.
enum WioKey {
  WIO_INPUT_UP = 0,
  WIO_INPUT_DOWN = 1,
  WIO_INPUT_LEFT = 2,
  WIO_INPUT_RIGHT = 3,
  WIO_INPUT_A = 4,
  WIO_INPUT_B = 5,
  WIO_INPUT_C = 6,
  WIO_INPUT_N0 = 21,
  WIO_INPUT_N1 = 22,
  WIO_INPUT_N2 = 23,
  WIO_INPUT_N3 = 24,
  WIO_INPUT_N4 = 25,
  WIO_INPUT_N5 = 26,
  WIO_INPUT_N6 = 27,
  WIO_INPUT_N7 = 28,
  WIO_INPUT_N8 = 29,
  WIO_INPUT_N9 = 30,
  WIO_INPUT_PLUS = 31,
  WIO_INPUT_MINUS = 32,
  WIO_INPUT_MULTIPLY = 33,
  WIO_INPUT_DIVIDE = 34,
  WIO_INPUT_PERIOD = 35,
  WIO_INPUT_KEY_COUNT = 36,
};

// Create the LVGL display bound to the board's LCD (RGB565, partial render mode
// with a small draw buffer -- a full framebuffer would nearly exhaust SRAM).
// Also installs the LVGL tick/delay source. Returns the display, or nullptr on
// failure.
lv_display_t* wio_display_create(int32_t hor_res, int32_t ver_res);

// Configure the button / 5-way switch GPIOs (INPUT_PULLUP, active low). Call
// once from setup() before scanning.
void wio_input_init(void);

// Read the current button state as a bitmask of (1ull << WioKey). A set bit
// means the key is currently held.
uint64_t wio_input_scan(void);
