// Wio Terminal firmware entry point -- P1 hardware bring-up.
//
// This first slice proves the HAL compiles and runs on the board without the
// mruby interpreter: it stands up the LVGL display (wio_display_create), scans
// the buttons (wio_input_scan), and draws a small status screen that echoes the
// pressed keys. Arduino owns the event loop, so loop() pumps LVGL once per
// iteration -- the same "host owns the loop" shape the Emscripten build uses,
// where a callback runs one main_loop instead of a blocking Ruby `loop`.
//
// The mruby interpreter, SD-backed asset loading, and the real RPG2k scene tree
// are wired in the following P1/P3 slices (see app/wio/README.md); this build
// intentionally links neither libmruby nor the mruby input bridge.

#include <Arduino.h>
#include <lvgl.h>

#include "wio.hxx"

namespace {

lv_obj_t* g_status_label = nullptr;

// Names for the RGSS key ids, indexed by WioKey, for the on-screen echo.
const char* const kKeyNames[WIO_INPUT_KEY_COUNT] = {
    "Up", "Down", "Left", "Right", "A", "B", "C"};

void build_ui(void) {
  lv_obj_t* scr = lv_screen_active();
  lv_obj_set_style_bg_color(scr, lv_color_black(), 0);

  lv_obj_t* title = lv_label_create(scr);
  lv_label_set_text(title, "rpg2k on Wio Terminal\nP1 HAL bring-up");
  lv_obj_set_style_text_color(title, lv_color_white(), 0);
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 10);

  g_status_label = lv_label_create(scr);
  lv_label_set_text(g_status_label, "Keys: (none)");
  lv_obj_set_style_text_color(g_status_label, lv_palette_main(LV_PALETTE_AMBER),
                              0);
  lv_obj_align(g_status_label, LV_ALIGN_CENTER, 0, 20);
}

// Rebuild the "Keys:" line from the current button bitmask.
void show_keys(uint32_t mask) {
  static uint32_t last = 0xffffffffu;
  if (mask == last)
    return;
  last = mask;

  char buf[64];
  int n = 0;
  n += snprintf(buf + n, sizeof(buf) - n, "Keys:");
  bool any = false;
  for (int k = 0; k < WIO_INPUT_KEY_COUNT && n < static_cast<int>(sizeof(buf));
       ++k) {
    if (mask & (1u << k)) {
      n += snprintf(buf + n, sizeof(buf) - n, " %s", kKeyNames[k]);
      any = true;
    }
  }
  if (!any)
    snprintf(buf + n, sizeof(buf) - n, " (none)");
  lv_label_set_text(g_status_label, buf);
}

}  // namespace

void setup(void) {
  lv_init();
  wio_display_create(320, 240);
  wio_input_init();
  build_ui();
}

void loop(void) {
  show_keys(wio_input_scan());
  lv_timer_handler();
  delay(5);
}
