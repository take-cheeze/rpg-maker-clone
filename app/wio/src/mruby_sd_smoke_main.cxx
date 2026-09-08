// Standalone smoke test for ADR 0099's mechanism (loading mrblib bytecode
// from a file instead of embedding it) on real emulated hardware: reads a
// plain RITE binary (compiled from mruby-lcf's own mrblib/schema.rb +
// lcf.rb, this project's actual code, not a synthetic stand-in) off the SD
// card, loads it with mrb_load_irep_buf, and checks the resulting
// LCF::Schema constants through mruby's own C API -- the same check ADR
// 0099's host-side round-trip used, just retargeted to run on the board.
//
// Deliberately links no gem at all, not even mruby-lcf's own C extension:
// the file already carries mruby-lcf's compiled Ruby, and this only
// exercises the pure-Ruby schema/reader constants (no File I/O), so nothing
// beyond bare mruby core is needed. Verification is two parameterless
// functions (test_pass/test_fail) rather than Serial output: Renode's own
// boot script (scripts/wio_renode_boot.bash) already hooks setup()/loop()
// by PC address rather than modelling the USB-CDC UART, so this reuses that
// same proven mechanism instead of adding a new one.
//
// Not a permanent firmware target -- see docs/adr/0099-mruby-bytecode-runtime-load.md's
// Consequences for why this exists and what it does and does not prove.
//
// UNVERIFIED as written: `pio run -e wio_mruby_sd_smoke` has never
// completed a single build. PlatformIO needs api.registry.platformio.org /
// collector.platformio.org to fetch the Arduino/SAMD51 framework, and both
// were blocked by the network policy in the sandbox this was written in.
// Treat every API call here (Seeed_FS's File::read signature, the mruby
// hash/symbol macros) as reviewed-but-not-compiled until a real `pio run`
// has actually produced firmware.elf and it has booted under Renode
// (scripts/wio_renode_boot.bash, with PC hooks on test_pass/test_fail --
// see app/wio/renode/boot.resc for the pattern to copy).

#include <Arduino.h>
#include <Seeed_FS.h>
#include "SD/Seeed_SD.h"

#include <mruby.h>
#include <mruby/irep.h>
#include <mruby/variable.h>
#include <mruby/hash.h>
#include <mruby/string.h>

#ifndef SDCARD_SS_PIN
#define SDCARD_SS_PIN 1
#endif
#ifndef SDCARD_SPI
#define SDCARD_SPI SPI
#endif

namespace {

const char kBytecodePath[] = "/lcf_only.mrb";

// mrb_open_mrbgems() (called from mrb_open()) requires this even with zero
// gems configured -- see build_config.rb's rpg_maker_gems for the same
// story on the desktop/psp/android side. No gems means nothing to init.
extern "C" void mrb_init_mrbgems(mrb_state*) {}

uint8_t g_bytecode[64 * 1024];

// Marker functions Renode's boot script (see app/wio/renode/) hooks by PC
// address -- this project's own established way of observing a bare-metal
// firmware's outcome without a modelled UART. Never inlined/optimized away:
// each needs its own real address to hook.
__attribute__((noinline)) void test_pass() {
  __asm__ volatile("nop");
}
__attribute__((noinline)) void test_fail() {
  __asm__ volatile("nop");
}

bool check_schema(mrb_state* mrb) {
  mrb_value lcf = mrb_const_get(mrb, mrb_obj_value(mrb->object_class), mrb_intern_cstr(mrb, "LCF"));
  if (mrb->exc) return false;
  mrb_value schema = mrb_const_get(mrb, lcf, mrb_intern_cstr(mrb, "Schema"));
  if (mrb->exc) return false;
  mrb_value common_event = mrb_const_get(mrb, schema, mrb_intern_cstr(mrb, "COMMON_EVENT"));
  if (mrb->exc || !mrb_hash_p(common_event)) return false;
  if (mrb_hash_size(mrb, common_event) != 6) return false;

  mrb_value field11 = mrb_hash_get(mrb, common_event, mrb_fixnum_value(11));
  if (mrb->exc || !mrb_hash_p(field11)) return false;
  mrb_value name = mrb_hash_get(mrb, field11, mrb_symbol_value(mrb_intern_cstr(mrb, "name")));
  if (mrb->exc || !mrb_symbol_p(name)) return false;
  if (mrb_symbol(name) != mrb_intern_cstr(mrb, "start_term")) return false;

  mrb_value database = mrb_const_get(mrb, schema, mrb_intern_cstr(mrb, "DATABASE"));
  if (mrb->exc || !mrb_hash_p(database)) return false;
  mrb_value elements = mrb_hash_get(mrb, database, mrb_symbol_value(mrb_intern_cstr(mrb, "elements")));
  mrb_value player = mrb_hash_get(mrb, elements, mrb_fixnum_value(11));
  mrb_value player_elements = mrb_hash_get(mrb, player, mrb_symbol_value(mrb_intern_cstr(mrb, "elements")));
  mrb_value status_field = mrb_hash_get(mrb, player_elements, mrb_fixnum_value(31));
  mrb_value order = mrb_hash_get(mrb, status_field, mrb_symbol_value(mrb_intern_cstr(mrb, "order")));
  if (mrb->exc || !mrb_array_p(order)) return false;
  if (RARRAY_LEN(order) != 6) return false;
  mrb_value first = RARRAY_PTR(order)[0];
  if (!mrb_symbol_p(first)) return false;
  if (mrb_symbol(first) != mrb_intern_cstr(mrb, "max_hp")) return false;

  return true;
}

}  // namespace

void setup() {
  if (!SD.begin(SDCARD_SS_PIN, SDCARD_SPI)) {
    test_fail();
    return;
  }

  File f = SD.open(kBytecodePath, FILE_READ);
  if (!f) {
    test_fail();
    return;
  }
  const size_t n = f.read(g_bytecode, sizeof(g_bytecode));
  f.close();
  if (n == 0 || n >= sizeof(g_bytecode)) {
    test_fail();
    return;
  }

  mrb_state* mrb = mrb_open();
  if (!mrb) {
    test_fail();
    return;
  }

  mrb_load_irep_buf(mrb, g_bytecode, n);
  if (mrb->exc) {
    test_fail();
    return;
  }

  if (check_schema(mrb)) {
    test_pass();
  } else {
    test_fail();
  }
}

void loop() {}
