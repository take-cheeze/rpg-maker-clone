// M5Stack Core (Basic/Gray/Go, ESP32 + ILI9341) hardware backend for the RGSS
// runtime.
//
// This is the platform half of the M5Stack port: it stands up an LVGL display
// over the board's 320x240 ILI9341 SPI LCD (via TFT_eSPI, configured for the
// Core's pins through build_flags -- see app/m5stack/README.md), installs a
// millis()/delay() tick source (LVGL needs one without SDL, exactly as the
// terminal and Wio backends do), scans the three front buttons (A/B/C) into
// a bitmask, and can play a WAV file from the Core's microSD slot out its
// built-in speaker (see m5stack_audio_play_wav() below). Unlike the Wio
// Terminal's 5-way switch, the Core has no built-in D-pad, so the
// UP/DOWN/LEFT/RIGHT slots depend entirely on the M5Stack FACES kit's
// optional Gamepad Face bottom module (see the I2C protocol comment on
// m5stack_input_scan() below) -- with no Face attached, they read exactly like
// the Wio backend leaves the Numbers/Operators ids unbound for lack of a wired
// button (see M5Key below): reserved, never set.
//
// It deliberately knows nothing about mruby so it can be compiled for a
// board-bring-up firmware without the interpreter (see app/m5stack). The mruby
// side -- translating the button bitmask into RGSS::Input press/release events
// -- would be a separate m5stack_input_bridge.cxx, mirroring
// wio_input_bridge.cxx; not part of this HAL-only bring-up slice.
//
// The whole translation unit is compiled only when M5STACK_CORE is defined, so
// the desktop/wasm/wio/maix/psp builds (which glob every mruby-rgss/src/*.cxx
// into libmruby.a) see an empty file.

#pragma once

#include <cstdint>

#include <lvgl.h>

// Bit positions in the m5stack_input_scan() bitmask. They match the RGSS::Input
// key ids (mruby-rgss/mrblib/lib.rb), the same convention wio.hxx's WioKey
// uses. The mask is a uint64_t for the same reason wio.hxx's is: room for the
// RPG2003 Numbers/Operators ids (21..35), even though nothing on this board
// binds them.
enum M5Key {
  M5_INPUT_UP = 0,
  M5_INPUT_DOWN = 1,
  M5_INPUT_LEFT = 2,
  M5_INPUT_RIGHT = 3,
  M5_INPUT_A = 4,
  M5_INPUT_B = 5,
  M5_INPUT_C = 6,
  M5_INPUT_N0 = 21,
  M5_INPUT_N1 = 22,
  M5_INPUT_N2 = 23,
  M5_INPUT_N3 = 24,
  M5_INPUT_N4 = 25,
  M5_INPUT_N5 = 26,
  M5_INPUT_N6 = 27,
  M5_INPUT_N7 = 28,
  M5_INPUT_N8 = 29,
  M5_INPUT_N9 = 30,
  M5_INPUT_PLUS = 31,
  M5_INPUT_MINUS = 32,
  M5_INPUT_MULTIPLY = 33,
  M5_INPUT_DIVIDE = 34,
  M5_INPUT_PERIOD = 35,
  M5_INPUT_KEY_COUNT = 36,
};

// Create the LVGL display bound to the board's LCD (RGB565, partial render mode
// with a small draw buffer -- SRAM is only 520 KB on the -16M/GREY variants and
// far less (320 KB) on the base Core, so a full 320x240x2 framebuffer
// (150 KB) is avoidable, not free). Also installs the LVGL tick/delay source.
// Returns the display, or nullptr on failure.
lv_display_t* m5stack_display_create(int32_t hor_res, int32_t ver_res);

// Configure the A/B/C button GPIOs. GPIO 34-39 are input-only on the ESP32 and
// have no internal pull resistor, so this is a plain INPUT, not INPUT_PULLUP --
// the board itself carries the pull-up. Also starts the I2C bus (Wire) and
// probes address 0x08 once to record whether a FACES Gamepad Face is
// attached (see m5stack_input_scan()'s own comment for the protocol) --
// mirroring the old M5Faces Arduino library's own canControlFaces() probe,
// so a missing Face costs one failed I2C transaction at boot, not one on
// every subsequent scan. Call once from setup() before scanning.
void m5stack_input_init(void);

// Read the current button state as a bitmask of (1ull << M5Key). A set bit
// means the key is currently held.
//
// If an M5Stack FACES kit Gamepad Face ("Game Face") bottom module is
// attached, this also polls it over I2C (Wire, SDA=GPIO21/SCL=GPIO22 -- the
// Core's internal/"Port A" bus the FACES bus connector carries through) at
// address 0x08, and ORs its buttons into the same mask: Up/Down/Left/Right
// fill the otherwise-always-unset UP/DOWN/LEFT/RIGHT bits, A/B OR into the
// same A/B bits the Core's own front buttons already set (either source
// presses the same logical button), and the Face's two extra buttons
// (Select/Start) have no RGSS button of their own, so -- mirroring the PSP
// backend's own spare-button convention (include/psp.hxx's own comment,
// mruby-rgss/src/psp.cxx) -- they land on the first two otherwise-unbound
// RPG2003 Numbers ids, M5_INPUT_N0 (Select) and M5_INPUT_N1 (Start).
//
// Protocol, verified directly against the module's own real firmware
// (github.com/m5stack/FACES-Firmware, GameBoy.ino -- the actual MEGA328
// source, not a guess from the module's marketing copy): every I2C read
// returns one byte, the live snapshot of the AVR's PORTB register
// (Wire.write(PINB) on every request, no register addressing and no write
// support at all -- the firmware never calls Wire.onReceive()). Active low,
// one bit per button: bit0 Up, bit1 Down, bit2 Left, bit3 Right, bit4 A,
// bit5 B, bit6 Select, bit7 Start. The module also carries an IRQ line
// (wired to GPIO5 on real M5Stack Core hardware) that pulses on a state
// change, but a plain read at any time already returns the live state
// regardless of it, so this HAL only polls and never wires that line.
//
// No Face attached (the common case: this module is an optional add-on) is
// not an error -- the I2C read simply gets NACKed, exactly like probing any
// other absent address, and this function treats that the same as "nothing
// pressed from the Face this frame" rather than logging or asserting.
uint64_t m5stack_input_scan(void);

// Starts the Core's microSD slot and configures the built-in speaker's DAC
// pin. Call once from setup(), after m5stack_display_create() -- the SD
// card shares the display's own SPI bus (CS=GPIO4, SCK=GPIO18, MISO=GPIO19,
// MOSI=GPIO23 -- the same SCK/MISO/MOSI TFT_eSPI's own build_flags already
// configure the LCD on, just a different CS line), and TFT_eSPI's own
// g_tft.begin() must be the one to first bring that bus up (confirmed
// directly: initializing SD first left the display uninitialized, matching
// a real-world caveat the M5Stack community has hit on this same shared-bus
// wiring). Returns whether the card mounted; false is not fatal to the rest
// of the HAL -- m5stack_audio_play_wav() below just fails gracefully with no
// card present, the same "optional peripheral, not there" shape as the
// FACES Gamepad Face above.
bool m5stack_audio_init(void);

// Plays one WAV file from the SD card (Arduino SD library path, e.g.
// "/bgm/town.wav") out the Core's built-in speaker, blocking until playback
// finishes. Returns false without playing anything if: no SD card mounted
// (m5stack_audio_init() failed or was never called), the file does not
// exist, or its header is not a PCM WAV format this decoder understands.
//
// Understands uncompressed PCM only (WAVE_FORMAT_PCM, format tag 1) at
// 8 or 16 bits per sample, mono or stereo, any sample rate the file itself
// declares -- covers what a real WAV asset built from PCM audio looks like,
// not RPG Maker's other BGM formats (OGG/MP3/MIDI), which stay out of scope
// here (see app/m5stack/README.md's own "Audio" section for why: no
// embeddable decoder for those currently exists in this tree, unlike this
// port's own TFT_eSPI/LVGL dependencies).
//
// Output path: every sample is downmixed to mono (stereo input is
// channel-averaged) and rescaled to 8-bit unsigned, then written with
// dacWrite() to GPIO25 -- one of the ESP32's two internal DAC channels,
// which is what the Core's built-in speaker amplifier is wired to (checked
// directly against M5Stack's own community documentation, not assumed from
// a generic ESP32 pinout). Playback is a plain blocking loop timed with
// delayMicroseconds() against the file's own declared sample rate -- no
// I2S DMA or hardware timer yet, so it is not sample-accurate and blocks
// the caller (LVGL, button scanning) for the file's whole duration. That is
// a real, documented limitation of this first cut, not a hidden one -- see
// the ADR for what a non-blocking, I2S-driven version would need instead.
bool m5stack_audio_play_wav(const char* path);
