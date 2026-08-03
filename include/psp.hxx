// Sony PlayStation Portable (Allegrex / pspsdk) hardware backend for the RGSS
// runtime.
//
// This is the platform half of the PSP port, mirroring the Wio Terminal backend
// (include/wio.hxx). It stands up an LVGL display over the PSP's 480x272 LCD
// via the raw display framebuffer (sceDisplay), installs an LVGL tick/delay
// source from the system timer (LVGL needs one without SDL, exactly as the
// terminal and Wio backends do), and scans the digital pad into a bitmask.
//
// Like wio.hxx it deliberately knows nothing about mruby, so it can be compiled
// into a board-bring-up EBOOT without the interpreter (see app/psp). The mruby
// side -- translating the button bitmask into RGSS::Input press/release events
// -- is the separate psp_input_bridge.cxx, mirroring the sdl_input.cxx
// (platform) / input_bridge.cxx (mruby) split used by the SDL backend.
//
// The whole translation unit is compiled only when PSP_BUILD is defined, so the
// desktop/wasm builds (which glob every mruby-rgss/src/*.cxx into libmruby.a)
// see an empty file.

#pragma once

#include <cstdint>

#include <lvgl.h>

// Bit positions in the psp_input_scan() bitmask. They match the RGSS::Input key
// ids (mruby-rgss/mrblib/lib.rb): bit (1u << id) is set while that key is held.
enum PspKey {
  PSP_INPUT_UP = 0,
  PSP_INPUT_DOWN = 1,
  PSP_INPUT_LEFT = 2,
  PSP_INPUT_RIGHT = 3,
  PSP_INPUT_A = 4,
  PSP_INPUT_B = 5,
  PSP_INPUT_C = 6,
  PSP_INPUT_KEY_COUNT = 7,
};

// The PSP's native resolution. The panel is 480x272; the display controller
// reads it with a 512-pixel line stride (BUF_WIDTH), which the flush callback
// accounts for.
constexpr int32_t PSP_SCR_WIDTH = 480;
constexpr int32_t PSP_SCR_HEIGHT = 272;
constexpr int32_t PSP_BUF_WIDTH = 512;

// Create the LVGL display bound to the PSP LCD (RGB565, partial render mode
// with a RAM draw buffer that the flush callback copies into the VRAM
// framebuffer). Also installs the LVGL tick/delay source from the system timer.
// Returns the display, or nullptr on failure.
lv_display_t* psp_display_create(int32_t hor_res, int32_t ver_res);

// Configure controller sampling. Call once before scanning.
void psp_input_init(void);

// Read the current pad state as a bitmask of (1u << PspKey). A set bit means
// the key is currently held. The D-pad (and the analog stick, treated as a
// coarse D-pad) drive the direction keys; Cross/Circle/Triangle map to C/B/A to
// match the desktop Z/X/C = confirm/cancel/A convention.
uint32_t psp_input_scan(void);
