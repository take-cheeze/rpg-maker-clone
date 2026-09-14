// Sipeed Maix Amigo (Kendryte K210) hardware backend for the RGSS runtime.
//
// This is the platform half of the Maix port: it stands up an LVGL display
// over the board's 320x480 TFT (SPI, driven through Maixduino's
// Sipeed_ST7789), installs a millis()/delay() tick source (LVGL needs one
// without SDL, exactly as the terminal backend does), and scans input
// (capacitive touch + user key) into a bitmask.
//
// It deliberately knows nothing about mruby so the display/input pieces can
// be compiled for a firmware without the interpreter ever being linked --
// and, unlike the Wio port, all of it lives on the PlatformIO side
// (app/wio/src/maix_*.cxx, one translation unit per piece): nothing here
// needs Arduino headers at mruby rake time, so there is no Arduino-include
// escape hatch to maintain. The mruby side -- translating the input bitmask
// into RGSS::Input press/release events -- is rgss_maix_poll below (same
// file, mruby.h only), mirroring the sdl_input.cxx (platform) /
// input_bridge.cxx (mruby) split used by the SDL backend.
//
// The whole translation units are compiled as ordinary PlatformIO sources;
// the MAIX_WITH_SD syscalls are the only part behind a macro (see
// maix_sd_syscalls.cxx).

#pragma once

#include <cstdint>

#include <lvgl.h>

// Bit positions in the maix_input_scan() bitmask. They match the RGSS::Input
// key ids (mruby-rgss/mrblib/lib.rb): bit (1ull << id) is set while that key
// is held. Only what the board can actually produce is bound: a capacitive
// touch tap is Confirm, anything else is a follow-up once the menu work
// needs directions (touch regions) -- see app/maix/README.md.
enum MaixKey {
  MAIX_INPUT_UP = 0,
  MAIX_INPUT_DOWN = 1,
  MAIX_INPUT_LEFT = 2,
  MAIX_INPUT_RIGHT = 3,
  MAIX_INPUT_A = 4,
  MAIX_INPUT_B = 5,
  MAIX_INPUT_C = 6,
  MAIX_INPUT_KEY_COUNT = 7,
};

// Create the LVGL display bound to the board's LCD (RGB565, full-frame
// buffer from the newlib heap -- 320x480x2 = 300 KB, affordable on this
// board's 8 MB SRAM, unlike the Wio Terminal's partial buffers). Also
// installs the LVGL tick/delay source. Returns the display, or nullptr on
// failure (in particular when the framebuffer malloc fails).
lv_display_t* maix_display_create(int32_t hor_res, int32_t ver_res);

// The framebuffer maix_display_create allocated (RGB565, hor_res*ver_res
// words), exposed so diagnostics can read back what LVGL actually rendered
// -- telling a render problem from a flush problem while this HAL is being
// brought up. Null when creation failed.
extern uint16_t* g_maix_framebuffer;

// Start the touch controller. Call once from setup() before scanning.
void maix_input_init(void);

// Read the current input state as a bitmask of (1ull << MaixKey). A set bit
// means the key is currently held.
uint32_t maix_input_scan(void);

// Initialise the SD card (Maixduino SD over SPI0, TF slot). Returns true on
// success. Call once from setup() before any game file is opened; without
// it (or without a card) the maix_sd_syscalls.cxx layer answers ENOENT.
// Only defined when MAIX_WITH_SD is set (see that file).
#ifdef MAIX_WITH_SD
bool maix_sd_init(void);
#endif
