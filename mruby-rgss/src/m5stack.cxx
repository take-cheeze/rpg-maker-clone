// M5Stack Core (ESP32) LVGL display + input HAL. See include/m5stack.hxx for
// the contract and why this file is a no-op unless M5STACK_CORE is defined.

#ifdef M5STACK_CORE

#include "m5stack.hxx"

#include <Arduino.h>
#include <TFT_eSPI.h>  // configured for the Core's ILI9341 via build_flags
#include <Wire.h>  // FACES Gamepad Face, see m5stack_input_scan() in m5stack.hxx

#include <SD.h>  // microSD-backed WAV playback, see m5stack_audio_play_wav()

#include <cstring>

namespace {

// The board's LCD driver. Pins/driver are supplied entirely through
// build_flags (-DUSER_SETUP_LOADED=1 and friends -- see
// app/m5stack/README.md), not a checked-in User_Setup.h, so this same
// TFT_eSPI works for any M5Stack Core variant wired the standard way.
TFT_eSPI g_tft;

// LVGL partial-render draw buffers, the same shape and sizing rationale as
// wio.cxx's: ten rows of RGB565 across the 320-wide panel is 320*10*2 =
// 6.4 KB each, two buffers so a bulk SPI flush of one can overlap rendering
// into the other.
constexpr int32_t kPanelWidth = 320;
constexpr int32_t kBufRows = 10;
uint8_t g_buf1[kPanelWidth * kBufRows * 2];
uint8_t g_buf2[kPanelWidth * kBufRows * 2];

uint32_t tick_cb(void) {
  return static_cast<uint32_t>(millis());
}

void delay_cb(uint32_t ms) {
  delay(ms);
}

// Push one rendered rectangle to the LCD. LVGL hands RGB565 pixels; the panel
// expects byte-swapped RGB565, so setSwapBytes(true) is set once at init.
void flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
  const int32_t w = lv_area_get_width(area);
  const int32_t h = lv_area_get_height(area);

  g_tft.startWrite();
  g_tft.setAddrWindow(area->x1, area->y1, w, h);
  g_tft.pushColors(reinterpret_cast<uint16_t*>(px_map),
                   static_cast<uint32_t>(w) * h, true);
  g_tft.endWrite();

  lv_display_flush_ready(disp);
}

// M5Stack Core's three front buttons. GPIO 34-39 are ESP32 input-only pins
// with no internal pull resistor; the board itself pulls each line high, so
// these are read with a plain INPUT (see m5stack_input_init below), active
// low, same polarity as every other board this project reads buttons on.
struct PinMap {
  uint8_t pin;
  uint8_t key;
};

constexpr uint8_t kButtonAPin = 39;
constexpr uint8_t kButtonBPin = 38;
constexpr uint8_t kButtonCPin = 37;

const PinMap kPins[] = {
    {kButtonAPin, M5_INPUT_A},
    {kButtonBPin, M5_INPUT_B},
    {kButtonCPin, M5_INPUT_C},
};

// M5Stack Core's internal I2C ("Port A") bus, the same one the FACES bus
// connector carries through to a Gamepad Face -- see m5stack_input_scan()'s
// own doc comment in m5stack.hxx for the full protocol this decodes.
constexpr uint8_t kFacesGamepadI2cAddr = 0x08;
constexpr uint8_t kI2cSdaPin = 21;
constexpr uint8_t kI2cSclPin = 22;

bool g_gamepad_face_present = false;

// Bit -> M5Key for the Face's own D-pad and A/B, decoded from the byte
// m5stack_input_scan() reads at kFacesGamepadI2cAddr. A/B intentionally
// share the Core's own front-button ids (see that comment); Select/Start
// have no bits of their own in kPins above since nothing else on this board
// can press them.
struct GamepadBitMap {
  uint8_t bit;
  uint8_t key;
};

const GamepadBitMap kGamepadBits[] = {
    {0, M5_INPUT_UP},    {1, M5_INPUT_DOWN}, {2, M5_INPUT_LEFT},
    {3, M5_INPUT_RIGHT}, {4, M5_INPUT_A},    {5, M5_INPUT_B},
    {6, M5_INPUT_N0},  // Select
    {7, M5_INPUT_N1},  // Start
};

// The Core's microSD slot, on the same VSPI bus as the display (see
// m5stack_audio_init()'s own doc comment in m5stack.hxx) -- just its own CS
// line. GPIO25 is one of the ESP32's two internal 8-bit DAC channels, and
// the pin the Core's built-in speaker amplifier is wired to.
constexpr uint8_t kSdCsPin = 4;
constexpr uint8_t kSpeakerDacPin = 25;

bool g_sd_available = false;

uint32_t read_u32le(File& f) {
  uint8_t b[4];
  if (f.read(b, 4) != 4)
    return 0;
  return static_cast<uint32_t>(b[0]) | (static_cast<uint32_t>(b[1]) << 8) |
         (static_cast<uint32_t>(b[2]) << 16) |
         (static_cast<uint32_t>(b[3]) << 24);
}

uint16_t read_u16le(File& f) {
  uint8_t b[2];
  if (f.read(b, 2) != 2)
    return 0;
  return static_cast<uint16_t>(b[0]) |
         static_cast<uint16_t>(static_cast<uint16_t>(b[1]) << 8);
}

// One frame (all channels of one sample instant) downmixed to mono and
// rescaled to the DAC's native 8-bit unsigned range. `frame` points at
// channels * (bits_per_sample / 8) raw bytes.
uint8_t downmix_frame(const uint8_t* frame,
                      uint16_t channels,
                      uint16_t bits_per_sample) {
  if (bits_per_sample == 8) {
    if (channels == 1)
      return frame[0];
    return static_cast<uint8_t>((static_cast<uint16_t>(frame[0]) + frame[1]) /
                                2);
  }
  // 16-bit signed PCM, little-endian.
  const int16_t left =
      static_cast<int16_t>(frame[0] | (static_cast<uint16_t>(frame[1]) << 8));
  int32_t mono16 = left;
  if (channels == 2) {
    const int16_t right =
        static_cast<int16_t>(frame[2] | (static_cast<uint16_t>(frame[3]) << 8));
    mono16 = (static_cast<int32_t>(left) + right) / 2;
  }
  // Signed 16-bit -> unsigned 8-bit: shift the zero point up by half the
  // range, then keep the high byte.
  return static_cast<uint8_t>((mono16 + 32768) >> 8);
}

}  // namespace

lv_display_t* m5stack_display_create(int32_t hor_res, int32_t ver_res) {
  g_tft.begin();
  // Rotation 1: landscape, buttons/USB-C at the bottom -- the Core's usual
  // hand-held orientation.
  g_tft.setRotation(1);
  g_tft.setSwapBytes(true);
  g_tft.fillScreen(TFT_BLACK);

  lv_tick_set_cb(tick_cb);
  lv_delay_set_cb(delay_cb);

  lv_display_t* disp = lv_display_create(hor_res, ver_res);
  if (!disp)
    return nullptr;

  lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
  lv_display_set_buffers(disp, g_buf1, g_buf2, sizeof(g_buf1),
                         LV_DISPLAY_RENDER_MODE_PARTIAL);
  lv_display_set_flush_cb(disp, flush_cb);
  return disp;
}

void m5stack_input_init(void) {
  for (const PinMap& p : kPins)
    pinMode(p.pin, INPUT);

  Wire.begin(kI2cSdaPin, kI2cSclPin);
  Wire.beginTransmission(kFacesGamepadI2cAddr);
  g_gamepad_face_present = (Wire.endTransmission() == 0);
}

uint64_t m5stack_input_scan(void) {
  uint64_t mask = 0;
  for (const PinMap& p : kPins) {
    if (digitalRead(p.pin) == LOW)  // active low
      mask |= (1ull << p.key);
  }

  if (g_gamepad_face_present &&
      Wire.requestFrom(kFacesGamepadI2cAddr, static_cast<uint8_t>(1)) == 1) {
    const uint8_t state = Wire.read();
    for (const GamepadBitMap& b : kGamepadBits) {
      if (!(state & (1u << b.bit)))  // active low
        mask |= (1ull << b.key);
    }
  }

  return mask;
}

bool m5stack_audio_init(void) {
  g_sd_available = SD.begin(kSdCsPin);
  return g_sd_available;
}

bool m5stack_audio_play_wav(const char* path) {
  if (!g_sd_available)
    return false;

  File f = SD.open(path, FILE_READ);
  if (!f)
    return false;

  char tag[4];
  if (f.read(reinterpret_cast<uint8_t*>(tag), 4) != 4 ||
      std::memcmp(tag, "RIFF", 4) != 0) {
    f.close();
    return false;
  }
  read_u32le(f);  // overall RIFF size, unused
  if (f.read(reinterpret_cast<uint8_t*>(tag), 4) != 4 ||
      std::memcmp(tag, "WAVE", 4) != 0) {
    f.close();
    return false;
  }

  bool have_fmt = false, have_data = false;
  uint16_t audio_format = 0, channels = 0, bits_per_sample = 0;
  uint32_t sample_rate = 0, data_size = 0;

  // Chunks after "WAVE" can appear in any order and some (LIST, fact, ...)
  // are neither "fmt " nor "data" -- skip anything else rather than assuming
  // a fixed layout, the same defensive shape most real WAV writers expect a
  // reader to have.
  while (!have_data && f.available() >= 8) {
    if (f.read(reinterpret_cast<uint8_t*>(tag), 4) != 4)
      break;
    const uint32_t chunk_size = read_u32le(f);

    if (std::memcmp(tag, "fmt ", 4) == 0 && chunk_size >= 16) {
      audio_format = read_u16le(f);
      channels = read_u16le(f);
      sample_rate = read_u32le(f);
      read_u32le(f);  // byte rate, recomputed rather than trusted
      read_u16le(f);  // block align, likewise
      bits_per_sample = read_u16le(f);
      have_fmt = true;
      const uint32_t remaining = chunk_size - 16;
      if (remaining > 0)
        f.seek(f.position() + remaining);
    } else if (std::memcmp(tag, "data", 4) == 0) {
      data_size = chunk_size;
      have_data = true;  // raw samples start right here; stop scanning
    } else {
      // RIFF chunks are word-aligned: an odd-sized chunk has one pad byte
      // after it that is not part of the next chunk's own header.
      f.seek(f.position() + chunk_size + (chunk_size & 1));
    }
  }

  const bool supported = have_fmt && have_data && audio_format == 1 /* PCM */ &&
                         (bits_per_sample == 8 || bits_per_sample == 16) &&
                         (channels == 1 || channels == 2) && sample_rate > 0;
  if (!supported) {
    f.close();
    return false;
  }

  const uint32_t bytes_per_frame = channels * (bits_per_sample / 8);
  const uint32_t frame_count = data_size / bytes_per_frame;
  const uint32_t interval_us = 1000000u / sample_rate;

  uint8_t buf[256];
  const uint32_t frames_per_read = sizeof(buf) / bytes_per_frame;
  uint32_t frames_left = frame_count;

  while (frames_left > 0) {
    const uint32_t frames_this_read =
        frames_left < frames_per_read ? frames_left : frames_per_read;
    const size_t bytes_to_read = frames_this_read * bytes_per_frame;
    if (f.read(buf, bytes_to_read) != bytes_to_read)
      break;  // truncated file -- stop rather than play whatever is left

    for (uint32_t i = 0; i < frames_this_read; ++i) {
      dacWrite(kSpeakerDacPin, downmix_frame(buf + i * bytes_per_frame,
                                             channels, bits_per_sample));
      delayMicroseconds(interval_us);
    }
    frames_left -= frames_this_read;
  }

  f.close();
  return true;
}

#endif  // M5STACK_CORE
