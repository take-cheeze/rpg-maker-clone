// Boot test for the Wio Terminal's closed-world libmruby: it opens the VM,
// brings up the RGSS/mruby-lcf/mruby-rpg2k gem set, then exercises the LVGL HAL
// (compiled into libmruby.a, mruby-rgss/src/wio.cxx) and the button scan.
//
// No game is played yet: the boot only looks for the game's files (the microSD
// card's game folder, then the QSPI game image; wio_game_rom.cxx) and shows
// where they would come from. The status screen echoes the pressed keys.
//
// Deliberately does NOT define its own mrb_init_mrbgems: libmruby.a already
// carries the real, generated one build_config.rb's own
// rpg_maker_gem_dispatch produces -- defining a second one here would be a
// libmruby.a already carries the real, generated one build_config.rb's own
// rpg_maker_gem_dispatch produces -- defining a second one here would be a
// duplicate-symbol link error. mrb_open_core() + the same
// rpg_maker_init_shared_gems/rpg_maker_init_rpg2k_gem two-step
// src/main.cxx's own desktop build uses is what actually runs it, in the
// same order.

#include <Arduino.h>
#include <lvgl.h>

#include <mruby.h>
#include <mruby/error.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <cstdio>
#include <cstring>

#include "wio.hxx"
#include "wio_game_rom.h"
#include "wio_qspi_xip.h"
#include "wio_sd.h"

extern "C" void rpg_maker_init_shared_gems(mrb_state* mrb);
extern "C" void rpg_maker_init_rpg2k_gem(mrb_state* mrb);
extern "C" unsigned rgss_wio_mrb_state_size(void);

namespace {

volatile uint32_t g_result = 0;
constexpr uint32_t kResultPass = 0xC0FFEE43;  // one past mruby_sd_smoke's 42
constexpr uint32_t kResultFailMrbOpenCore = 0xBAD20001;
constexpr uint32_t kResultFailSharedGems = 0xBAD20002;
constexpr uint32_t kResultFailRpg2kGem = 0xBAD20003;
// MRB_STATE_LAYOUT: libmruby and this file disagree on sizeof(mrb_state).
constexpr uint32_t kResultFailLayout = 0xBAD20004;

// Debug aid, same convention as mruby_sd_smoke_main.cxx's g_exc_class:
// readable via Renode `sysbus ReadByte` in a loop when g_result comes back
// one of the kResultFail* codes above.
char g_exc_class[64] = {0};

// RUBY_ENTRY: a Ruby raise is a C++ throw (MRB_USE_CXX_EXCEPTION), and the
// Arduino core, LVGL and this file have no handler for it, so one that left
// libmruby here would end in std::terminate. Every call into mruby from
// setup() runs as an mrb_protect_error body; build_src_flags gives this file
// unwind tables so the throw can pass through the bodies to that catch.
struct ExcReport {
  RObject* exc;
  const char* step;
};

mrb_value report_exc(mrb_state* mrb, void* data) {
  const ExcReport& r = *static_cast<const ExcReport*>(data);
  const mrb_value e = mrb_obj_value(r.exc);
  std::strncpy(g_exc_class, mrb_obj_classname(mrb, e), sizeof(g_exc_class) - 1);
  RBasic* mesg = mrb_exc_ptr(e)->mesg;
  int len = 0;
  const char* text = "";
  if (mesg && mesg->tt == MRB_TT_STRING) {
    const mrb_value m = mrb_obj_value(mesg);
    len = static_cast<int>(RSTRING_LEN(m));
    text = RSTRING_PTR(m);
  }
  std::fprintf(stderr, "[RGSS] %s raised %s: %.*s\n", r.step, g_exc_class, len,
               text);
  return mrb_nil_value();
}

// Records and logs the exception a boot step left in mrb->exc. Naming it can
// itself raise (an allocation), so that is protected too.
void record_exc(mrb_state* mrb, const char* step) {
  if (!mrb->exc)
    return;
  ExcReport r = {mrb->exc, step};
  mrb_protect_error(mrb, report_exc, &r, nullptr);
}

// Runs one boot step; a raise out of it is left in mrb->exc, as
// mrb_open_core leaves its own.
void run_step(mrb_state* mrb, mrb_protect_error_func* body) {
  mrb_bool failed = FALSE;
  const mrb_value exc = mrb_protect_error(mrb, body, nullptr, &failed);
  if (failed)
    mrb->exc = mrb_obj_ptr(exc);
}

mrb_value init_shared_gems(mrb_state* mrb, void*) {
  rpg_maker_init_shared_gems(mrb);
  return mrb_nil_value();
}

mrb_value init_rpg2k_gem(mrb_state* mrb, void*) {
  rpg_maker_init_rpg2k_gem(mrb);
  return mrb_nil_value();
}

mrb_value full_gc(mrb_state* mrb, void*) {
  mrb_full_gc(mrb);
  return mrb_nil_value();
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

// Names for the RGSS key ids, indexed by WioKey, for the on-screen echo.
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
  wio_qspi_xip_require();
  lv_init();
  wio_display_create(320, 240);
  wio_input_init();

  if (rgss_wio_mrb_state_size() != sizeof(mrb_state)) {
    g_result = kResultFailLayout;
    build_ui("mrb_state layout differs from libmruby");
    return;
  }
  mrb_state* M = mrb_open_core();
  if (!M || M->exc) {
    if (M)
      record_exc(M, "mrb_open_core");
    g_result = kResultFailMrbOpenCore;
    build_ui("mrb_open_core failed");
    return;
  }

  run_step(M, init_shared_gems);
  if (M->exc) {
    record_exc(M, "rpg_maker_init_shared_gems");
    g_result = kResultFailSharedGems;
    build_ui(g_exc_class);
    return;
  }

  run_step(M, init_rpg2k_gem);
  if (M->exc) {
    record_exc(M, "rpg_maker_init_rpg2k_gem");
    g_result = kResultFailRpg2kGem;
    build_ui(g_exc_class);
    return;
  }

  // Every class/method this firmware will ever define is now registered --
  // rpg_maker_init_shared_gems/_rpg2k_gem is the only place anything calls
  // mrb_load_irep, and nothing past this point loads more Ruby. That load
  // path itself allocates real GC-tracked scaffolding along the way (RProc/
  // Array wrapper objects mrb_load_irep builds while walking each IREP
  // tree, not retained by the classes/methods it ends up defining), which
  // would otherwise just sit as garbage until the VM's own incremental GC
  // happens to cross its threshold sometime during the main loop. A single
  // full sweep here, before `loop()` (Arduino's own main routine) starts,
  // reclaims it up front instead -- cheap (a one-time boot cost, not a
  // per-frame one) and returned to the same newlib heap
  // LVGL's own allocations now draw from too.
  run_step(M, full_gc);
  record_exc(M, "mrb_full_gc");

  g_result = kResultPass;
  build_ui("mruby+RGSS+LVGL: OK");

#if WIO_QSPI_XIP
  const char* game = wio_game_files_begin();
#else
  // The QSPI window is never opened: there is no game image to look at.
  const char* game = wio_sd_state_text(wio_sd_begin());
#endif
  lv_obj_t* game_label = lv_label_create(lv_screen_active());
  lv_label_set_text(game_label, game);
  lv_obj_set_style_text_color(game_label, lv_color_white(), 0);
  lv_obj_align(game_label, LV_ALIGN_CENTER, 0, 80);

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
