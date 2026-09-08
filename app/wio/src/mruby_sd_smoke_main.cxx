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
//   2. Real memory ceiling. mruby-lcf's schema.rb originally defined all 25
//      record types (~930 fields total, ADR 0098's own count) as nested
//      hash literals executed in one shot; loading the *whole* file this
//      way raised NoMemoryError on the Wio's 192 KB SRAM under a stock
//      Arduino SAMD malloc arena.
//
// UPDATE (2026-09-08): mruby-lcf/mrblib/schema.rb's large top-level
// constants (DATABASE's own 17 biggest per-record-type `elements:` values,
// plus 15 more standalone constants -- SAVE_SYSTEM, SAVE_MOVABLE, etc --
// referenced the same way) are now `-> { {...} } ` lambdas, resolved and
// cached on first real access (LCF.elements_of, mruby-lcf/mrblib/lcf.rb) --
// see that file's own comment for why some of these self-memoize instead
// (`Schema.lazy`) and MAP_UNIT/MAP_TREE/DATABASE/SAVE_DATA's own top-level
// Hashes stay eager (used as a `.lmu`/`.lmt`/`.ldb`/`.lsd` file's root
// schema directly, never through an `elements:` indirection). Verified
// byte-for-byte structurally identical to the pre-change file for every
// LCF::Schema constant via an automated deep-resolve comparison (force
// every lambda, diff against the original), and the existing ctest suite
// (2052 assertions, mruby-lcf's own `test/lcf_test.rb` included) passes
// unchanged.
//
// On real emulated hardware this closes *part* of finding 2: the real,
// complete, unmodified-content schema.rb + lcf.rb (now ~54 KB compiled,
// not a synthetic reduction) loads cleanly through mrb_load_irep_buf --
// something the pre-laziness file could not do at all. It does not close
// the finding entirely: resolving even one record type's lazy fields
// afterward (DATABASE chunk 11, "player", ~30 fields -- see check_schema
// below) still exhausts what little headroom is left in *this test's*
// current layout and crashes the same way the original all-eager file
// did (PC lands in newlib's abort/_exit path, not a catchable mrb->exc --
// consistent with mruby's own "out of memory while raising NoMemoryError"
// fallback). g_bytecode below shrank from 64 KB to 60 KB specifically to
// buy the headroom that made the *load* succeed; there was no slack left
// over for anything past it. The likely dominant remaining costs are the
// interpreter's own IREP structures for the ~54 KB of bytecode (a cost
// that scales with total compiled size, not with how much Ruby data is
// actually live) and lcf.rb's ~700 lines of real reader/writer code --
// neither shrinks just because schema.rb's data got lazier. Closing the
// rest for real looks like mrb_load_irep_file streamed from an actual
// FILE* (app/wio/src/sd_syscalls.cxx already provides the newlib _open/
// _read plumbing for this, gated by WIO_WITH_SD, and is unwired today)
// instead of this test's whole-file-into-a-static-buffer
// mrb_load_irep_buf, which needs the entire compiled size resident in RAM
// on top of whatever the parse itself allocates.

#include <Arduino.h>
#include <Seeed_FS.h>
#include "SD/Seeed_SD.h"

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <mruby/hash.h>
#include <mruby/irep.h>
#include <mruby/string.h>
#include <mruby/variable.h>
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

uint8_t g_bytecode[60 * 1024];

// Debug aid: the raised exception's class name, ASCII, readable via Renode
// `sysbus ReadByte` in a loop (or a hex dump) when g_result comes back
// kResultFailLoadIrep/kResultFailMrbOpen -- otherwise "unknown exception
// raised" is all a magic-number result code alone would say.
char g_exc_class[64] = {0};
volatile uint32_t g_bytes_read = 0;
volatile uint32_t g_file_size = 0;

void record_exc(mrb_state* mrb) {
  if (!mrb->exc)
    return;
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
// Written after confirming DATABASE's chunk 11 elements: is still an
// unresolved Proc (laziness held all the way through mrb_load_irep_buf) --
// isolates that finding from whatever #call (resolving chunk 11's ~30 real
// fields) does next.
constexpr uint32_t kResultLazyConfirmed = 0x1A2100D;

void test_pass() {
  g_result = kResultPass;
}
void test_fail(uint32_t code) {
  g_result = code;
}

// Checks COMMON_EVENT/BGM/SE/LEARNING/BATTLER_ANIMATION (already-eager,
// small constants), then reaches into DATABASE's chunk 11 (player) the same
// way real game code does -- through the lazy `elements:` lambda, not a
// hash literal -- to confirm the laziness actually held: LOADING the whole
// file does not force it. /lcf_only.mrb on the SD card for this smoke test
// is the real, complete mruby-lcf/mrblib/lcf.rb + schema.rb, not a reduced
// slice; see this file's own header comment for how far this gets on real
// hardware today (the load succeeds; resolving chunk 11's fields via #call,
// past kResultLazyConfirmed below, still does not -- kept here rather than
// removed since a future fix narrowing that gap should re-run this exact
// check to see it finally pass end to end).
bool check_schema(mrb_state* mrb) {
  mrb_value lcf = mrb_const_get(mrb, mrb_obj_value(mrb->object_class),
                                mrb_intern_cstr(mrb, "LCF"));
  if (mrb->exc)
    return false;
  mrb_value schema = mrb_const_get(mrb, lcf, mrb_intern_cstr(mrb, "Schema"));
  if (mrb->exc)
    return false;
  mrb_value common_event =
      mrb_const_get(mrb, schema, mrb_intern_cstr(mrb, "COMMON_EVENT"));
  if (mrb->exc || !mrb_hash_p(common_event))
    return false;
  if (mrb_hash_size(mrb, common_event) != 6)
    return false;

  mrb_value field11 = mrb_hash_get(mrb, common_event, mrb_fixnum_value(11));
  if (mrb->exc || !mrb_hash_p(field11))
    return false;
  mrb_value name = mrb_hash_get(mrb, field11,
                                mrb_symbol_value(mrb_intern_cstr(mrb, "name")));
  if (mrb->exc || !mrb_symbol_p(name))
    return false;
  if (mrb_symbol(name) != mrb_intern_cstr(mrb, "start_term"))
    return false;

  mrb_value battler_animation =
      mrb_const_get(mrb, schema, mrb_intern_cstr(mrb, "BATTLER_ANIMATION"));
  if (mrb->exc || !mrb_hash_p(battler_animation))
    return false;
  mrb_value field14 =
      mrb_hash_get(mrb, battler_animation, mrb_fixnum_value(14));
  if (mrb->exc || !mrb_hash_p(field14))
    return false;
  mrb_value field14_name = mrb_hash_get(
      mrb, field14, mrb_symbol_value(mrb_intern_cstr(mrb, "name")));
  if (mrb->exc || !mrb_symbol_p(field14_name))
    return false;
  if (mrb_symbol(field14_name) != mrb_intern_cstr(mrb, "battle_animation_id"))
    return false;

  mrb_value database =
      mrb_const_get(mrb, schema, mrb_intern_cstr(mrb, "DATABASE"));
  if (mrb->exc || !mrb_hash_p(database))
    return false;
  mrb_value db_elements = mrb_hash_get(
      mrb, database, mrb_symbol_value(mrb_intern_cstr(mrb, "elements")));
  if (mrb->exc || !mrb_hash_p(db_elements))
    return false;
  mrb_value chunk11 = mrb_hash_get(mrb, db_elements, mrb_fixnum_value(11));
  if (mrb->exc || !mrb_hash_p(chunk11))
    return false;
  mrb_value chunk11_elements = mrb_hash_get(
      mrb, chunk11, mrb_symbol_value(mrb_intern_cstr(mrb, "elements")));
  // Must still be an unresolved Proc here -- this is the point of the fix:
  // building all of chunk 11's ~30 fields never happened just from getting
  // this far.
  if (mrb->exc || !mrb_proc_p(chunk11_elements))
    return false;
  g_result = kResultLazyConfirmed;

  mrb_value resolved = mrb_funcall(mrb, chunk11_elements, "call", 0);
  if (mrb->exc || !mrb_hash_p(resolved))
    return false;
  mrb_value field31 = mrb_hash_get(mrb, resolved, mrb_fixnum_value(31));
  if (mrb->exc || !mrb_hash_p(field31))
    return false;
  mrb_value field31_name = mrb_hash_get(
      mrb, field31, mrb_symbol_value(mrb_intern_cstr(mrb, "name")));
  if (mrb->exc || !mrb_symbol_p(field31_name))
    return false;
  if (mrb_symbol(field31_name) != mrb_intern_cstr(mrb, "status"))
    return false;

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
    if (got == 0)
      break;
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
