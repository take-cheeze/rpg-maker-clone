// M5Stack Core firmware entry point -- P1 hardware bring-up.
//
// Mirrors app/wio/src/main.cxx's own P1 slice: proves the HAL compiles and
// runs on the board without the mruby interpreter. It stands up the LVGL
// display (m5stack_display_create), scans the three A/B/C buttons
// (m5stack_input_scan), and draws a small status screen that echoes the
// pressed keys -- plus a Serial println per state change, since the QEMU
// smoke test (scripts/m5stack_qemu_boot.bash) has no display to read (see
// app/m5stack/README.md, "What the emulator can and cannot show"). Arduino
// owns the event loop, so loop() pumps LVGL once per iteration.
//
// The mruby interpreter, SD-backed asset loading, and the real RPG2k scene
// tree are later slices (see app/m5stack/README.md); this build intentionally
// links neither libmruby nor the mruby input bridge.

#include <Arduino.h>
#include <lvgl.h>

#include "m5stack.hxx"

namespace {

lv_obj_t* g_status_label = nullptr;

// Names for the RGSS key ids, indexed by M5Key, for the on-screen/serial echo.
const char* const kKeyNames[M5_INPUT_KEY_COUNT] = {
    "Up", "Down", "Left", "Right", "A", "B", "C"};

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
void show_keys(uint32_t mask) {
  static uint32_t last = 0xffffffffu;
  if (mask == last)
    return;
  last = mask;

  char buf[64];
  int n = 0;
  n += snprintf(buf + n, sizeof(buf) - n, "Keys:");
  bool any = false;
  for (int k = 0; k < M5_INPUT_KEY_COUNT && n < static_cast<int>(sizeof(buf));
       ++k) {
    if (mask & (1u << k)) {
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
  build_ui();
  // The one fixed marker scripts/m5stack_qemu_boot.bash waits for -- printed
  // once setup() has run every HAL init call above without hanging.
  Serial.println("m5stack: setup complete");
}

void loop(void) {
  show_keys(m5stack_input_scan());
  lv_timer_handler();
  delay(5);
}
