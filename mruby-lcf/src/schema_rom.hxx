// ROM_SCHEMA: LCF::Schema's Hashes as constant tables
// (mruby-lcf/gen_schema_rom.rb writes them and describes the format). Ruby
// holds a node as its handle, a negative Integer; LCF.rom_get / LCF.rom_keys
// answer Hash#[] / Hash#keys for it, so no schema Hash is ever built.
//
// Included by lcf.cxx and by scripts/bc2cpp-rpg/lcf_schema_rom_check.rb.
#pragma once

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <cstdint>

struct lcf_rom_ext_entry {
  uint8_t kind;
  uint32_t a;
  uint32_t b;
};

extern const unsigned lcf_rom_node_count;
extern const unsigned lcf_rom_ext_count;
extern const uint16_t lcf_rom_node_first[];
extern const uint16_t lcf_rom_pairs[];
extern const lcf_rom_ext_entry lcf_rom_ext[];
extern const uint16_t lcf_rom_words[];
extern const double lcf_rom_doubles[];
extern const char lcf_rom_pool[];

// A word holds a Symbol as its presym id. lcf_schema_rom_check.rb links a
// libmruby without the schema's presyms and maps the words to its own ids.
#ifndef LCF_ROM_WORD_SYM
#define LCF_ROM_WORD_SYM(w) static_cast<mrb_sym>(w)
#define LCF_ROM_SYM_WORD(s) ((s) < 0x8000 ? static_cast<uint16_t>(s) : 0)
#define LCF_ROM_LEAVES_SYM(M) MRB_SYM(__lcf_rom_leaves)
#endif

namespace lcf_rom {

// The check collects before each ext value is built (-DLCF_SCHEMA_STRESS), so
// a value not rooted while it is made is swept and the comparison fails.
#ifdef LCF_SCHEMA_STRESS
#define LCF_ROM_GC(M) mrb_full_gc(M)
#else
#define LCF_ROM_GC(M) ((void)0)
#endif

inline unsigned node_of(mrb_state* M, mrb_value h) {
  if (!mrb_integer_p(h)) {
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(TypeError)),
               "schema node handle is %T, not Integer", h);
  }
  const mrb_int v = mrb_integer(h);
  if (v >= 0 || static_cast<mrb_uint>(-(v + 1)) >= lcf_rom_node_count) {
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(IndexError)),
               "no schema node %i", v);
  }
  return static_cast<unsigned>(-(v + 1));
}

mrb_value word_value(mrb_state* M, uint16_t w);

// One object per ext entry and mrb_state, as one Hash held one: the first read
// builds it, later reads return it. The slots hang off LCF under a name no
// Ruby ivar can spell, which also roots them.
inline mrb_value ext_value(mrb_state* M, unsigned i) {
  const lcf_rom_ext_entry& e = lcf_rom_ext[i];
  if (e.kind == 0) {
    return mrb_int_value(M, static_cast<int32_t>(e.a));
  }
  RObject* lcf = reinterpret_cast<RObject*>(mrb_module_get(M, "LCF"));
  mrb_value slots = mrb_obj_iv_get(M, lcf, LCF_ROM_LEAVES_SYM(M));
  if (mrb_nil_p(slots)) {
    slots = mrb_ary_new_capa(M, static_cast<mrb_int>(lcf_rom_ext_count));
    mrb_obj_iv_set(M, lcf, LCF_ROM_LEAVES_SYM(M), slots);
  }
  mrb_value v = mrb_ary_entry(slots, static_cast<mrb_int>(i));
  if (!mrb_nil_p(v)) {
    return v;
  }
  LCF_ROM_GC(M);
  switch (e.kind) {
    case 1:
      v = mrb_str_new(M, lcf_rom_pool + e.a, e.b);
      break;
    case 2:
#ifndef MRB_NO_FLOAT
      v = mrb_float_value(M, lcf_rom_doubles[e.a]);
#else
      // The parser reads a Float literal as 0 under MRB_NO_FLOAT, so
      // schema.rb's own Hash held 0.
      v = mrb_fixnum_value(0);
#endif
      break;
    default: {
      v = mrb_ary_new_capa(M, static_cast<mrb_int>(e.b));
      const int ai = mrb_gc_arena_save(M);
      for (uint32_t k = 0; k < e.b; ++k) {
        mrb_ary_push(M, v, word_value(M, lcf_rom_words[e.a + k]));
        mrb_gc_arena_restore(M, ai);
      }
    }
  }
  mrb_ary_set(M, slots, static_cast<mrb_int>(i), v);
  return v;
}

inline mrb_value word_value(mrb_state* M, uint16_t w) {
  if (!(w & 0x8000)) {
    return mrb_symbol_value(LCF_ROM_WORD_SYM(w));
  }
  const unsigned op = w & 0xfff;
  switch ((w >> 12) & 7) {
    case 0:
      return mrb_fixnum_value(-static_cast<mrb_int>(op) - 1);
    case 1:
      return mrb_fixnum_value(op & 0x800 ? static_cast<mrb_int>(op) - 0x1000
                                         : static_cast<mrb_int>(op));
    case 2:
      return ext_value(M, op);
    default:
      return op == 0 ? mrb_nil_value() : mrb_bool_value(op == 1);
  }
}

// The key word Hash#[] would match, or 0 (no pair has it) for a key no schema
// Hash holds: only Symbols and Integers 0 .. 0x7fff are keys, and eql? never
// matches another class.
inline uint16_t key_word(mrb_value key) {
  if (mrb_symbol_p(key)) {
    return LCF_ROM_SYM_WORD(mrb_symbol(key));
  }
  if (mrb_integer_p(key)) {
    const mrb_int i = mrb_integer(key);
    return i >= 0 && i <= 0x7fff ? static_cast<uint16_t>(0x8000 | i) : 0;
  }
  return 0;
}

// Hash#[] of node `h`: the value of `key`, or nil.
inline mrb_value get(mrb_state* M, mrb_value h, mrb_value key) {
  const unsigned n = node_of(M, h);
  const uint16_t k = key_word(key);
  if (k == 0) {
    return mrb_nil_value();
  }
  for (unsigned p = lcf_rom_node_first[n]; p < lcf_rom_node_first[n + 1]; ++p) {
    if (lcf_rom_pairs[2 * p] == k) {
      return word_value(M, lcf_rom_pairs[2 * p + 1]);
    }
  }
  return mrb_nil_value();
}

// Hash#keys of node `h`: a new Array, in insertion (source) order.
inline mrb_value keys(mrb_state* M, mrb_value h) {
  const unsigned n = node_of(M, h);
  const unsigned first = lcf_rom_node_first[n];
  const unsigned last = lcf_rom_node_first[n + 1];
  mrb_value out = mrb_ary_new_capa(M, static_cast<mrb_int>(last - first));
  for (unsigned p = first; p < last; ++p) {
    const uint16_t k = lcf_rom_pairs[2 * p];
    mrb_ary_push(M, out,
                 k & 0x8000 ? mrb_fixnum_value(k & 0x7fff)
                            : mrb_symbol_value(LCF_ROM_WORD_SYM(k)));
  }
  return out;
}

}  // namespace lcf_rom
