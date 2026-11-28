// Wio Terminal (Seeed, ATSAMD51) hardware backend for the RGSS runtime.
//
// This is the platform half of the Wio port: it stands up the RGSS display over
// the board's 320x240 ILI9341 SPI LCD (the own compositor's, gfx_own.cxx), with
// a millis()/delay() clock, and scans the three top buttons and the 5-way
// switch into a bitmask.
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

struct mrb_state;

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

// Start the LCD and create the display (RGB565, drawn a strip of rows at a
// time -- a full framebuffer would nearly exhaust SRAM), black. False on
// failure.
bool wio_display_begin(int32_t hor_res, int32_t ver_res);

// Hand the display to RGSS (rgss_set_display).
void wio_display_attach(mrb_state* M);

// Called with every rectangle the display draws (RGB565, rows w apart) in
// place of the push to the LCD; nullptr pushes again.
typedef void (*WioFlushHook)(int32_t x,
                             int32_t y,
                             int32_t w,
                             int32_t h,
                             const uint16_t* px);
void wio_display_set_flush_hook(WioFlushHook hook);

// Draw on every Graphics.update rather than at most once per refresh period.
void wio_display_draw_every_frame(void);

// Status text straight on the LCD, centred on x, in the panel's built-in font,
// over a black box `pad` pixels wide (0: the text's own width). For a firmware
// that runs no game; a game's frames draw over it.
void wio_display_text(int32_t x,
                      int32_t y,
                      uint16_t rgb565,
                      int32_t pad,
                      const char* text);

// Configure the button / 5-way switch GPIOs (INPUT_PULLUP, active low). Call
// once from setup() before scanning.
void wio_input_init(void);

// Read the current button state as a bitmask of (1ull << WioKey). A set bit
// means the key is currently held.
uint64_t wio_input_scan(void);
