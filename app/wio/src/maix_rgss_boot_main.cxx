// Maix Amigo firmware: link libmruby.a and boot the interpreter.
//
// The `maix_amigo` environment proves the toolchain produces a binary; this
// one proves the cross-built interpreter (build_config.rb's `maix` target,
// scripts/maix_mruby_build.bash) actually links into a firmware and runs on
// the chip: setup() opens mruby (running every configured gem's init, the
// full RPG2k+LCF+RGSS stack), evaluates a string, and reports the result
// over Serial. No LVGL display, no game scene yet -- the display HAL and the
// real scene tree are the next slices (see app/maix/README.md); nothing here
// creates a display, so LVGL links but never runs.
//
// Lives under app/wio/src/ only because platformio.ini sets a single,
// project-wide `src_dir` (see maix_amigo_main.cxx's own comment for why).

#include <Arduino.h>

#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>

namespace {

// Evaluated inside the opened interpreter; the smoke test (CI's maix-smoke
// job, scripts/maix_renode_boot.bash) asserts this exact line on Serial.
// Kept side-effect free on purpose: no game code runs here, only proof the
// parser, the VM and string handling all work on this chip.
constexpr char kProbe[] = "\"maix-ruby-alive\"";

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

}  // namespace

void setup(void) {
  Serial.begin(115200);
  Serial.println("maix-rgss-boot: opening mruby");

  mrb_state* mrb = mrb_open();
  if (mrb == nullptr) {
    Serial.println("maix-rgss-boot: mrb_open failed");
    return;
  }
  Serial.println("maix-rgss-boot: mrb_open ok");
  report_string(mrb, mrb_load_string(mrb, kProbe));
  mrb_close(mrb);
  Serial.println("maix-rgss-boot: done");
}

void loop(void) {
  static bool on = false;
  on = !on;
  digitalWrite(LED_GREEN, on ? HIGH : LOW);
  Serial.print("maix-rgss-boot heartbeat: ");
  Serial.println(millis());
  delay(1000);
}
