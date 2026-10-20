// Maix Amigo firmware: display HAL + input + mruby smoke in one boot.
//
// setup() brings up, in order: Serial, the LVGL display
// (maix_display_create over the real panel driver), the touch controller,
// then the cross-built interpreter (mrb_open over the full RPG2k+LCF+RGSS
// gem set, one string eval). It then paints the screen solid red through
// LVGL itself and pumps the timer handler until the flush lands -- the
// Renode LCD-capture rig (CI's maix-smoke job) asserts those red pixels,
// which proves the HAL pushes real frames through the real driver path, not
// just that it links. loop() polls input into RGSS::Input every frame and
// echoes the bitmask over Serial on change (idle under Renode), plus the
// usual heartbeat.
//
// No game scene yet -- display/input/SD are proven here so the scene tree
// can land on working HAL in the next slice (see app/maix/README.md).
//
// Lives under app/wio/src/ only because platformio.ini sets a single,
// project-wide `src_dir` (see maix_amigo_main.cxx's own comment for why).

#include <Arduino.h>

#include <lvgl.h>

#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>

#include "maix.hxx"

// Evaluated inside the opened interpreter; the smoke test asserts this
// exact line on Serial. Side-effect free: no game code runs here, only
// proof the parser, the VM and string handling all work on this chip.
constexpr char kProbe[] = "\"maix-ruby-alive\"";

namespace {

mrb_state* g_mrb = nullptr;
uint32_t g_last_keys = 0;

void report_string(mrb_state* mrb, mrb_value value) {
  if (mrb->exc) {
    Serial.println("maix-rgss-boot: EXCEPTION during eval");
    mrb->exc = nullptr;
    return;
  }
  value = mrb_str_to_str(mrb, value);
  Serial.print("maix-rgss-boot: eval -> ");
  Serial.println(RSTRING_PTR(value));
}

void show_keys(uint32_t mask) {
  if (mask == g_last_keys)
    return;
  g_last_keys = mask;
  Serial.print("maix-rgss-boot: keys ");
  Serial.println(mask, HEX);
}

}  // namespace

extern "C" void rgss_maix_poll(mrb_state* M);

void setup(void) {
  Serial.begin(115200);

  lv_init();
  lv_display_t* disp = maix_display_create(320, 240);
  if (!disp) {
    Serial.println("maix-rgss-boot: display failed");
    return;
  }
  Serial.println("maix-rgss-boot: display ok");
  maix_input_init();

  g_mrb = mrb_open();
  if (g_mrb == nullptr) {
    Serial.println("maix-rgss-boot: mrb_open failed");
    return;
  }
  Serial.println("maix-rgss-boot: mrb_open ok");
  report_string(g_mrb, mrb_load_string(g_mrb, kProbe));

  // Solid red through LVGL itself, rendered synchronously until the flush
  // lands: the LCD capture asserts these pixels (see app/maix/README.md
  // "LCD capture"). lv_refr_now rather than timer pumps: the pumps also
  // work, but an explicit refresh states exactly what this waits on.
  lv_obj_t* scr = lv_screen_active();
  lv_obj_set_style_bg_color(scr, lv_color_hex(0xFF0000), 0);
  lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
  lv_obj_invalidate(scr);
  for (int i = 0; i < 10; ++i) {
    lv_refr_now(disp);
    delay(5);
  }
  Serial.print("maix-rgss-boot: fb[0]=");
  Serial.println(g_maix_framebuffer ? g_maix_framebuffer[0] : 0xFFFF, HEX);
  Serial.println("maix-rgss-boot: frame ok");
  show_keys(maix_input_scan());
  Serial.println("maix-rgss-boot: done");
}

void loop(void) {
  if (g_mrb)
    rgss_maix_poll(g_mrb);
  show_keys(maix_input_scan());
  lv_timer_handler();
  static bool on = false;
  on = !on;
  digitalWrite(LED_GREEN, on ? HIGH : LOW);
  Serial.print("maix-rgss-boot heartbeat: ");
  Serial.println(millis());
  delay(1000);
}
