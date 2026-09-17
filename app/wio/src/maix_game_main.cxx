// Maix Amigo firmware: boot the maix-hello game to its title screen.
//
// setup() brings up Serial, mounts the SD card (env:maix_game_sd only --
// see the MAIX_WITH_SD block below), the LVGL display, touch input, the
// virtual gamepad (maix_gamepad.cxx -- the board has no physical buttons;
// drawn once, straight to the panel's margins, outside RPG2k's own canvas
// entirely, so nothing the game itself ever draws can cover it) and the
// interpreter (same stack as maix_rgss_boot_main.cxx), then -- instead of
// evaluating a probe string -- boots a real game the way src/main.cxx's
// desktop build does: inject the display, set GAME_DIR (flash-resident by
// default, served by maix_embed.cxx; SD-resident under MAIX_WITH_SD) and
// RTP_DIR (empty: self-contained), construct RPG2k with no CLI args, and
// pin it against the GC. loop() runs one main_loop iteration per pass (the
// Emscripten frame-loop ownership pattern: Arduino owns the loop, Ruby owns
// the frame), pumps LVGL and input, prints the active scene name every 60
// frames for the log, and reports a Ruby exception once instead of
// spamming it.
//
// Lives under app/wio/src/ only because platformio.ini sets a single,
// project-wide `src_dir` (see maix_amigo_main.cxx's own comment for why).

#include <Arduino.h>

#include <lvgl.h>

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/compile.h>
#include <mruby/gc.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include "maix.hxx"

extern "C" void rgss_set_display(mrb_state* M, lv_display_t* display);
extern "C" void rgss_maix_poll(mrb_state* M);

namespace {

mrb_state* g_mrb = nullptr;
mrb_value g_game = mrb_nil_value();
bool g_failed = false;
int g_frame = 0;

void report_scene(void) {
  mrb_value name = mrb_funcall(g_mrb, g_game, "current_scene_name", 0);
  if (g_mrb->exc) {
    g_mrb->exc = nullptr;
    return;
  }
  name = mrb_str_to_str(g_mrb, name);
  Serial.print("maix-game scene: ");
  Serial.println(RSTRING_PTR(name));
}

void report_exc(void) {
  mrb_value exc = mrb_obj_value(g_mrb->exc);
  mrb_value cls = mrb_funcall(g_mrb, exc, "class", 0);
  mrb_value cname = mrb_funcall(g_mrb, cls, "to_s", 0);
  mrb_value msg = mrb_funcall(g_mrb, exc, "message", 0);
  cname = mrb_str_to_str(g_mrb, cname);
  msg = mrb_str_to_str(g_mrb, msg);
  Serial.print("maix-game EXCEPTION: ");
  Serial.print(RSTRING_PTR(cname));
  Serial.print(" ");
  Serial.println(RSTRING_PTR(msg));
  // First frames of the Ruby backtrace, so a failure names its call site
  // without needing a debugger attached to the board.
  mrb_value bt = mrb_funcall(g_mrb, exc, "backtrace", 0);
  if (!mrb_nil_p(bt)) {
    mrb_int len = RARRAY_LEN(bt);
    for (mrb_int i = 0; i < len && i < 8; ++i) {
      mrb_value line = mrb_str_to_str(g_mrb, mrb_ary_ref(g_mrb, bt, i));
      Serial.print("maix-game   at ");
      Serial.println(RSTRING_PTR(line));
    }
  }
  g_mrb->exc = nullptr;
}

}  // namespace

void setup(void) {
  Serial.begin(115200);
  Serial.println("maix-game: setup");

#ifdef MAIX_WITH_SD
  // Mounted ahead of lv_init/maix_display_create: the SD card (SPI1) and
  // the LCD (SPI0, see maix_display.cxx) are independent buses with
  // nothing to arbitrate, so ordering is only a matter of taste here.
  Serial.println("maix-game: sd mounting...");
  const bool sd_ok = maix_sd_init();
  Serial.print("maix-game: sd ");
  Serial.println(sd_ok ? "ok" : "absent");
#endif

  lv_init();
  Serial.println("maix-game: lv_init");
  lv_display_t* disp = maix_display_create(320, 240);
  if (!disp) {
    Serial.println("maix-game: display failed");
    return;
  }
  Serial.println("maix-game: display ok");
  maix_input_init();
  Serial.println("maix-game: input ok");
  maix_gamepad_create();
  Serial.println("maix-game: gamepad ok");

  g_mrb = mrb_open();
  if (g_mrb == nullptr) {
    Serial.println("maix-game: mrb_open failed");
    return;
  }
  rgss_set_display(g_mrb, disp);
#ifdef MAIX_WITH_SD
  // Game data lives on the card under /sd/<game> (pushed with
  // scripts/maix_sd_upload.py); the SD layer strips the /sd prefix, so the
  // card holds /maixgame/... (8.3-safe). Without the flag, embedded data.
  mrb_const_set(g_mrb, mrb_obj_value(g_mrb->object_class),
                mrb_intern_lit(g_mrb, "GAME_DIR"),
                mrb_str_new_cstr(g_mrb, "/sd/maixgame"));
#else
  mrb_const_set(g_mrb, mrb_obj_value(g_mrb->object_class),
                mrb_intern_lit(g_mrb, "GAME_DIR"),
                mrb_str_new_cstr(g_mrb, "/game"));
#endif
  mrb_const_set(g_mrb, mrb_obj_value(g_mrb->object_class),
                mrb_intern_lit(g_mrb, "RTP_DIR"), mrb_str_new_cstr(g_mrb, ""));

  mrb_value args = mrb_ary_new(g_mrb);
  // KNOWN ISSUE (env:maix_game_sd only, real hardware): this hangs, dead,
  // reading the SD card. Isolated with a raw fopen/fread bypassing mruby
  // entirely: fopen("/sd/maixgame/RPG_RT.ldb") succeeds (the directory-area
  // reads that resolve it all work, including a fresh re-upload -- ruled
  // out stale/corrupt data), but the first fread() on the file's own data
  // cluster never returns, even 15+s later, on a correctly-detected 32 GB
  // SDHC card. The hang is below Sd2Card::waitStartBlock's own
  // millis()-based timeout, so most likely inside the K210 SPI HAL's
  // untimed FIFO busy-wait (sipeed_spi_transfer_data_standard,
  // framework-maixduino's Maix_SPI.cpp).
  //
  // Originally found on SPI0 (see maix_tf_sd.h's own history) with a
  // hand-rolled DVP-mux dance shared with the LCD; moving the TF card to
  // SPI1 (the peripheral the official schematic actually specifies, no
  // sharing with anything) reproduces the identical hang, confirmed on
  // hardware -- so SPI0/DVP contention was a real correctness bug worth
  // fixing on its own, but not the cause of this one. Also confirmed
  // clock-speed-independent (400 kHz reproduces it too). Needs a
  // scope/logic analyzer on the SPI1 lines, or a different SD card to rule
  // out a media-specific fault -- env:maix_game (flash-embedded data) is
  // unaffected and boots to the title screen.
  Serial.println("maix-game: RPG2k.new...");
  g_game = mrb_obj_new(g_mrb, mrb_class_get(g_mrb, "RPG2k"), 1, &args);
  if (g_mrb->exc) {
    report_exc();
    return;
  }
  mrb_gc_register(g_mrb, g_game);
  Serial.println("maix-game: boot ok");
}

void loop(void) {
  if (g_mrb && !g_failed && !mrb_nil_p(g_game)) {
    mrb_funcall(g_mrb, g_game, "main_loop", 0);
    if (g_mrb->exc) {
      report_exc();
      g_failed = true;
    } else if (++g_frame % 60 == 0) {
      report_scene();
    }
  }
  if (g_mrb)
    rgss_maix_poll(g_mrb);
  lv_timer_handler();
  delay(5);
}
