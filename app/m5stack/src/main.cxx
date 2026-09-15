// M5Stack Core firmware entry point -- P1 hardware bring-up.
//
// Mirrors app/wio/src/main.cxx's own P1 slice: proves the HAL compiles and
// runs on the board without the mruby interpreter. It stands up the LVGL
// display (m5stack_display_create), scans the three A/B/C buttons plus
// whatever an attached FACES Gamepad Face adds (m5stack_input_scan), draws a
// small status screen that echoes the pressed keys, and -- on a fresh press
// of the Face's Start button specifically (see below for why that one) --
// tries to play a WAV file off the microSD card. All of it is echoed over
// Serial too, since the QEMU smoke test (scripts/m5stack_qemu_boot.bash) has
// no display to read (see app/m5stack/README.md, "What the emulator can and
// cannot show"). Arduino owns the event loop, so loop() pumps LVGL once per
// iteration.
//
// The mruby interpreter and the real RPG2k scene tree are later slices (see
// app/m5stack/README.md); this build intentionally links neither libmruby
// nor the mruby input bridge, so this WAV playback is a HAL-level demo of
// m5stack_audio_play_wav(), not RGSS::Audio (which needs the interpreter to
// even exist as an API surface).

#include <Arduino.h>
#include <lvgl.h>

#include "m5stack.hxx"

namespace {

lv_obj_t* g_status_label = nullptr;

// Names for the RGSS key ids, indexed by M5Key, for the on-screen/serial
// echo -- the full 36-entry table (mirroring app/psp/main.cxx's own
// kKeyNames), not just the 7 this board's own front buttons use, since
// M5_INPUT_N0/N1 are now reachable too (the FACES Gamepad Face's
// Select/Start, see m5stack_input_scan()'s doc comment) and an empty ""
// entry -- not a missing one -- is what show_keys() below skips; leaving
// the array short like the Core-only 7-button version used to would mean
// indexing a default-initialized nullptr for any bit beyond C's, which
// %s does not handle safely.
const char* const kKeyNames[M5_INPUT_KEY_COUNT] = {
    "Up", "Down", "Left", "Right",  "A",     "B",  "C",  "",   "",
    "",   "",     "",     "",       "",      "",   "",   "",   "",
    "",   "",     "",     "Select", "Start", "N2", "N3", "N4", "N5",
    "N6", "N7",   "N8",   "N9",     "+",     "-",  "*",  "/",  "."};

void build_ui(void) {
  lv_obj_t* scr = lv_screen_active();
  lv_obj_set_style_bg_color(scr, lv_color_black(), 0);

  lv_obj_t* title = lv_label_create(scr);
  lv_label_set_text(title, "rpg2k on M5Stack Core\nP1 HAL bring-up");
  lv_obj_set_style_text_color(title, lv_color_white(), 0);
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 10);

  g_status_label = lv_label_create(scr);
  lv_label_set_text(g_status_label, "Keys: (none)");
  lv_obj_set_style_text_color(g_status_label, lv_palette_main(LV_PALETTE_AMBER),
                              0);
  lv_obj_align(g_status_label, LV_ALIGN_CENTER, 0, 20);
}

// Rebuild the "Keys:" line from the current button bitmask, and echo the same
// text over Serial -- the only observable this firmware has under the QEMU
// smoke test, which boots the real ESP32 core but models no SPI display.
void show_keys(uint64_t mask) {
  static uint64_t last = 0xffffffffffffffffull;
  if (mask == last)
    return;
  last = mask;

  char buf[64];
  int n = 0;
  n += snprintf(buf + n, sizeof(buf) - n, "Keys:");
  bool any = false;
  for (int k = 0; k < M5_INPUT_KEY_COUNT && n < static_cast<int>(sizeof(buf));
       ++k) {
    if ((mask & (1ull << k)) && kKeyNames[k][0] != '\0') {
      n += snprintf(buf + n, sizeof(buf) - n, " %s", kKeyNames[k]);
      any = true;
    }
  }
  if (!any)
    snprintf(buf + n, sizeof(buf) - n, " (none)");
  lv_label_set_text(g_status_label, buf);
  Serial.println(buf);
}

}  // namespace

void setup(void) {
  Serial.begin(115200);
  lv_init();
  m5stack_display_create(320, 240);
  m5stack_input_init();
  // SD/DAC bring-up: does not gate "setup complete" below on a card being
  // present at all -- the microSD slot is exactly as optional as the FACES
  // Gamepad Face, and m5stack_audio_play_wav() already fails gracefully with
  // none mounted (see its own doc comment in m5stack.hxx).
  Serial.println(m5stack_audio_init() ? "SD: mounted" : "SD: not present");
  build_ui();
  // The one fixed marker scripts/m5stack_qemu_boot.bash waits for -- printed
  // once setup() has run every HAL init call above without hanging.
  Serial.println("m5stack: setup complete");
}

void loop(void) {
  const uint64_t mask = m5stack_input_scan();
  show_keys(mask);

  // Play a WAV file on a fresh press of the Gamepad Face's Start button
  // specifically, not any of the Core's own front buttons: those read
  // "held" for the whole run under the QEMU smoke test (no GPIO-injection
  // device exists there -- see app/m5stack/README.md), so triggering
  // playback off one of them would fire this exact block on literally every
  // boot; Start (M5_INPUT_N1) is unset unless a real Face -- or this repo's
  // own downstream QEMU Gamepad Face device with a simulated press -- is
  // actually present, making this a real edge trigger under both.
  static uint64_t last_mask = 0;
  const bool start_pressed_now = (mask & (1ull << M5_INPUT_N1)) != 0;
  const bool start_pressed_before = (last_mask & (1ull << M5_INPUT_N1)) != 0;
  if (start_pressed_now && !start_pressed_before) {
    const bool played = m5stack_audio_play_wav("/bgm.wav");
    Serial.println(played ? "Audio: played /bgm.wav" : "Audio: play failed");
  }
  last_mask = mask;

  lv_timer_handler();
  delay(5);
}

// env:m5stack builds Arduino as an ESP-IDF component (`framework = arduino,
// espidf`), not plain `framework = arduino` -- see docs/adr/0157's own
// follow-up: the precompiled Arduino static libs that plain mode links
// against fail a real assert in their own SPI flash re-probe under QEMU
// (do_core_init), while the exact same ESP-IDF version built from source as
// a component does not, isolating the bug to the precompiled libs
// specifically. Plain `framework = arduino` auto-generates this app_main()
// glue; the ESP-IDF component build does not, so it is written out here.
extern "C" void app_main(void) {
  initArduino();
  setup();
  while (true)
    loop();
}
