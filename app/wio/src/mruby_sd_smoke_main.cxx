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
// beyond bare mruby core is needed. Verification is a magic value written to
// a fixed global (g_result) rather than Serial output, read back with
// Renode's `sysbus ReadDoubleWord` after RunFor -- an earlier attempt hooked
// two parameterless test_pass()/test_fail() functions by PC address, mirroring
// how scripts/wio_renode_boot.bash hooks setup()/loop(), but the compiler
// folded their identical bodies into one address (both were just a nop), so
// they were not in fact distinguishable that way.
//
// VERIFIED (2026-09-08), on real emulated hardware, once two real bugs this
// smoke test surfaced were worked around -- see docs/adr/0099's Consequences
// for the full account and what's still open:
//   1. mrb_int size mismatch. build_config.rb's host mrbc defaults to
//      MRB_INT64 (64-bit host -> MRB_64BIT -> MRB_INT64, mrbconf.h's own
//      auto-detection), while psp/wio cross targets default to MRB_INT32.
//      A literal larger than 32 bits but smaller than mruby's bignum
//      threshold (mruby-lcf/mrblib/schema.rb has one -- a compile-time
//      constant-folded computation reducing to 2251799813685248) compiles
//      to an IREP_TT_INT64 pool entry the 32-bit reader cannot parse at
//      all (3rd/mruby/src/load.c's own `#else return FALSE #endif` under
//      `case IREP_TT_INT64:`), surfacing as a generic ScriptError
//      ("irep load error") with no hint of the real cause. Worked around
//      here with a scratch host mrbc forcing MRB_INT32 to match; not fixed
//      in build_config.rb itself, since forcing 32-bit ints onto the
//      shared host build affects desktop/wasm/android too and deserves its
//      own real look, not a rushed one alongside this ADR.
//   2. Real memory ceiling. mruby-lcf's schema.rb defines all 25 record
//      types (~930 fields total, ADR 0098's own count) as nested hash
//      literals executed in one shot; loading the *whole* file this way
//      raises NoMemoryError on the Wio's 192 KB SRAM under a stock Arduino
//      SAMD malloc arena. A smaller, still-real slice (COMMON_EVENT
//      through BATTLER_ANIMATION, ~27 fields, `head -75
//      mruby-lcf/mrblib/schema.rb`) loads and executes cleanly. Streaming
//      or splitting the schema is real follow-up work this smoke test
//      surfaced, not something it attempts.
// What this firmware carries: the int-size fix. What it does NOT carry:
// the exact scratch mruby-bigint/MRB_INT32 core build used to verify it
// (a local, uncommitted rake config -- see docs/adr/0099), or a
// memory-budgeted way to load the full schema.

#include <Arduino.h>
#include <Seeed_FS.h>
#include "SD/Seeed_SD.h"

#include <mruby.h>
#include <mruby/irep.h>
#include <mruby/variable.h>
#include <mruby/hash.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <cstring>

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

// Debug aid: the raised exception's class name, ASCII, readable via Renode
// `sysbus ReadByte` in a loop (or a hex dump) when g_result comes back
// kResultFailLoadIrep/kResultFailMrbOpen -- otherwise "unknown exception
// raised" is all a magic-number result code alone would say.
char g_exc_class[64] = {0};
volatile uint32_t g_bytes_read = 0;
volatile uint32_t g_file_size = 0;

void record_exc(mrb_state* mrb) {
  if (!mrb->exc) return;
  const char* name = mrb_obj_classname(mrb, mrb_obj_value(mrb->exc));
  std::strncpy(g_exc_class, name, sizeof(g_exc_class) - 1);
}

// Result marker: two distinct magic values (not two PC addresses -- a first
// attempt used identical-bodied test_pass()/test_fail() functions hooked by
// address the way boot.resc hooks setup()/loop(), but the compiler's
// identical-code folding merged them into one address, since both bodies
// were just a nop) written to a fixed global Renode reads back with
// `sysbus ReadDoubleWord` after RunFor, no UART needed.
volatile uint32_t g_result = 0;
constexpr uint32_t kResultPass = 0xC0FFEE42;
// Distinct per-stage codes rather than one generic failure value, so a
// Renode run can tell which stage failed without a modelled UART.
constexpr uint32_t kResultFailSdBegin = 0xBAD10001;
constexpr uint32_t kResultFailOpen = 0xBAD10002;
constexpr uint32_t kResultFailRead = 0xBAD10003;
constexpr uint32_t kResultFailMrbOpen = 0xBAD10004;
constexpr uint32_t kResultFailLoadIrep = 0xBAD10005;
constexpr uint32_t kResultFailCheck = 0xBAD10006;
// Written right after a successful mrb_load_irep_buf, before check_schema
// runs -- isolates "did the load itself succeed" from whatever check_schema
// does next, since check_schema calls mrb_const_get directly (unprotected)
// and a *missing* constant's raise path is untested on this target.
constexpr uint32_t kResultLoadedOk = 0x600D10AD;

void test_pass() {
  g_result = kResultPass;
}
void test_fail(uint32_t code) {
  g_result = code;
}

// Checks COMMON_EVENT/BGM/SE/LEARNING/BATTLER_ANIMATION only, not the full
// schema's DATABASE tree: DATABASE only exists when the *whole* 930-field
// schema.rb loads, and that does not fit today (see this file's own header
// comment, finding 2) -- so /lcf_only.mrb on the SD card for this smoke
// test must be the reduced slice (`head -75 mruby-lcf/mrblib/schema.rb`),
// not the real project's full file, or mrb_load_irep_buf itself fails
// with NoMemoryError before check_schema ever runs.
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

  mrb_value battler_animation = mrb_const_get(mrb, schema, mrb_intern_cstr(mrb, "BATTLER_ANIMATION"));
  if (mrb->exc || !mrb_hash_p(battler_animation)) return false;
  mrb_value field14 = mrb_hash_get(mrb, battler_animation, mrb_fixnum_value(14));
  if (mrb->exc || !mrb_hash_p(field14)) return false;
  mrb_value field14_name = mrb_hash_get(mrb, field14, mrb_symbol_value(mrb_intern_cstr(mrb, "name")));
  if (mrb->exc || !mrb_symbol_p(field14_name)) return false;
  if (mrb_symbol(field14_name) != mrb_intern_cstr(mrb, "battle_animation_id")) return false;

  return true;
}

}  // namespace

void setup() {
  if (!SD.begin(SDCARD_SS_PIN, SDCARD_SPI)) {
    test_fail(kResultFailSdBegin);
    return;
  }

  File f = SD.open(kBytecodePath, FILE_READ);
  if (!f) {
    test_fail(kResultFailOpen);
    return;
  }
  const uint32_t expected = f.size();
  // A single read() call is not guaranteed to fill the buffer even when
  // more data remains (block-at-a-time SD/FatFs reads, an internal chunk
  // size) -- loop until either the whole file is in or read() itself
  // reports it has nothing left, rather than trusting one call.
  size_t n = 0;
  while (n < sizeof(g_bytecode)) {
    const size_t got = f.read(g_bytecode + n, sizeof(g_bytecode) - n);
    if (got == 0) break;
    n += got;
  }
  f.close();
  g_bytes_read = (uint32_t)n;
  g_file_size = expected;
  if (n == 0 || n >= sizeof(g_bytecode) || n != expected) {
    test_fail(kResultFailRead);
    return;
  }

  mrb_state* mrb = mrb_open();
  if (!mrb) {
    test_fail(kResultFailMrbOpen);
    return;
  }

  mrb_load_irep_buf(mrb, g_bytecode, n);
  if (mrb->exc) {
    record_exc(mrb);
    test_fail(kResultFailLoadIrep);
    return;
  }
  g_result = kResultLoadedOk;

  if (check_schema(mrb)) {
    test_pass();
  } else {
    test_fail(kResultFailCheck);
  }
}

void loop() {}
