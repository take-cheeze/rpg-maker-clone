// Real mruby+RGSS+LVGL boot test for the Wio Terminal (ADR 0103's own
// follow-up, ADR 0007's P1 exit criteria): unlike app/wio/src/main.cxx's
// bring-up firmware ("proves the HAL... without the mruby interpreter"),
// this one actually opens the real interpreter -- linking the wio-target
// libmruby.a ADR 0103 first got building -- brings up the same RGSS/mruby-lcf
// /mruby-rpg2k gem set a real game would run, then exercises the LVGL HAL
// (wio.cxx, now compiled into libmruby.a itself rather than pulled in via
// app/wio/src/wio_hal.cxx's bring-up shim) and the button scan through it.
//
// No game data is loaded -- that needs the SD-backed asset streaming rework
// (ADR 0007's P3) libmruby.a alone does not touch. This proves the
// *interpreter* boots on real silicon and can still draw and read input
// through the same HAL the bring-up firmware already does, which is what P1
// actually asks for.
//
// Result is a status screen (mirrors main.cxx's own on-screen echo) plus a
// magic value in a fixed global, the same Renode-readable convention
// mruby_sd_smoke_main.cxx already established (`sysbus ReadDoubleWord`, no
// UART model needed) -- distinct per stage, so a Renode run can tell which
// step failed without a modelled serial port.
//
// Deliberately does NOT define its own mrb_init_mrbgems: unlike
// mruby_sd_smoke_main.cxx (which links no gem at all and so must stub it),
// libmruby.a already carries the real, generated one build_config.rb's own
// rpg_maker_gem_dispatch produces -- defining a second one here would be a
// duplicate-symbol link error. mrb_open_core() + the same
// rpg_maker_init_shared_gems/rpg_maker_init_rpg2k_gem two-step
// src/main.cxx's own desktop build uses is what actually runs it, in the
// same order.

#include <Arduino.h>
#include <lvgl.h>

#include <mruby.h>
#include <mruby/variable.h>

#include <cstdio>
#include <cstring>

#include "wio.hxx"

extern "C" void rpg_maker_init_shared_gems(mrb_state* mrb);
extern "C" void rpg_maker_init_rpg2k_gem(mrb_state* mrb);

namespace {

volatile uint32_t g_result = 0;
constexpr uint32_t kResultPass = 0xC0FFEE43;  // one past mruby_sd_smoke's 42
constexpr uint32_t kResultFailMrbOpenCore = 0xBAD20001;
constexpr uint32_t kResultFailSharedGems = 0xBAD20002;
constexpr uint32_t kResultFailRpg2kGem = 0xBAD20003;

// Debug aid, same convention as mruby_sd_smoke_main.cxx's g_exc_class:
// readable via Renode `sysbus ReadByte` in a loop when g_result comes back
// one of the kResultFail* codes above.
char g_exc_class[64] = {0};

void record_exc(mrb_state* mrb) {
  if (!mrb->exc)
    return;
  const char* name = mrb_obj_classname(mrb, mrb_obj_value(mrb->exc));
  std::strncpy(g_exc_class, name, sizeof(g_exc_class) - 1);
}

lv_obj_t* g_status_label = nullptr;

void build_ui(const char* status) {
  lv_obj_t* scr = lv_screen_active();
  lv_obj_set_style_bg_color(scr, lv_color_black(), 0);

  lv_obj_t* title = lv_label_create(scr);
  lv_label_set_text(title, "rpg2k on Wio Terminal\nreal mruby+RGSS boot");
  lv_obj_set_style_text_color(title, lv_color_white(), 0);
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 10);

  g_status_label = lv_label_create(scr);
  lv_label_set_text(g_status_label, status);
  lv_obj_set_style_text_color(g_status_label,
                              g_result == kResultPass
                                  ? lv_palette_main(LV_PALETTE_GREEN)
                                  : lv_palette_main(LV_PALETTE_RED),
                              0);
  lv_obj_align(g_status_label, LV_ALIGN_CENTER, 0, 20);
}

// Names for the RGSS key ids, indexed by WioKey, for the on-screen echo --
// same table app/wio/src/main.cxx's own bring-up firmware uses.
const char* const kKeyNames[WIO_INPUT_KEY_COUNT] = {
    "Up", "Down", "Left", "Right", "A", "B", "C"};

lv_obj_t* g_keys_label = nullptr;

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
  lv_label_set_text(g_keys_label, buf);
}

}  // namespace

void setup(void) {
  lv_init();
  wio_display_create(320, 240);
  wio_input_init();

  mrb_state* M = mrb_open_core();
  if (!M) {
    g_result = kResultFailMrbOpenCore;
    build_ui("mrb_open_core failed");
    return;
  }

  rpg_maker_init_shared_gems(M);
  if (M->exc) {
    record_exc(M);
    g_result = kResultFailSharedGems;
    build_ui(g_exc_class);
    return;
  }

  rpg_maker_init_rpg2k_gem(M);
  if (M->exc) {
    record_exc(M);
    g_result = kResultFailRpg2kGem;
    build_ui(g_exc_class);
    return;
  }

  g_result = kResultPass;
  build_ui("mruby+RGSS+LVGL: OK");

  g_keys_label = lv_label_create(lv_screen_active());
  lv_label_set_text(g_keys_label, "Keys: (none)");
  lv_obj_set_style_text_color(g_keys_label, lv_palette_main(LV_PALETTE_AMBER),
                              0);
  lv_obj_align(g_keys_label, LV_ALIGN_CENTER, 0, 50);
}

void loop(void) {
  if (g_keys_label)
    show_keys(wio_input_scan());
  lv_timer_handler();
  delay(5);
}
