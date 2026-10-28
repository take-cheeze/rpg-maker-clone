// SCHEMA_TABLES: decodes one of the field tables mruby-lcf/gen_schema_tables.rb
// folded out of mrblib/schema.rb's `elements:` lambdas. The wire format is
// described there. LCF.elements_of asks for a table the first time a record
// type is read and caches the Hash, so only the types a game touches are ever
// built; the bytes stay in .rodata.
//
// Included by lcf.cxx and by scripts/bc2cpp/lcf_schema_tables_check.rb, which
// decodes every table with a real mruby.
#pragma once

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/gc.h>
#include <mruby/hash.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <cstddef>
#include <cstring>

extern const char lcf_schema_pool[];
extern const unsigned lcf_schema_pool_off[];
extern const unsigned char lcf_schema_data[];
extern const unsigned lcf_schema_off[];
extern const unsigned lcf_schema_count;

// The check collects before every value is decoded (-DLCF_SCHEMA_STRESS), so a
// container that is not rooted while its elements are built is swept and the
// comparison fails.
#ifdef LCF_SCHEMA_STRESS
#define LCF_SCHEMA_GC(M) mrb_full_gc(M)
#else
#define LCF_SCHEMA_GC(M) ((void)0)
#endif

namespace lcf_schema {

struct Reader {
  mrb_state* M;
  RClass* schema;  // LCF::Schema, where a constant reference is resolved
  const unsigned char* p;

  unsigned varint() {
    unsigned v = 0;
    for (int shift = 0;; shift += 7) {
      const unsigned char b = *p++;
      v |= static_cast<unsigned>(b & 0x7f) << shift;
      if (!(b & 0x80))
        return v;
    }
  }

  const char* str(unsigned i, size_t* len) {
    *len = lcf_schema_pool_off[i + 1] - lcf_schema_pool_off[i] - 1;
    return lcf_schema_pool + lcf_schema_pool_off[i];
  }

  // The pool lives as long as the binary, so a Symbol names it without a copy.
  mrb_sym sym(unsigned i) {
    size_t len;
    const char* s = str(i, &len);
    return mrb_intern_static(M, s, len);
  }

  mrb_value value();

  // {name:, type:, [default:], [elements:], [other keys]}
  mrb_value field() {
    mrb_value h = mrb_hash_new_capa(M, 4);
    const int ai = mrb_gc_arena_save(M);
    mrb_hash_set(M, h, mrb_symbol_value(sym(0)),
                 mrb_symbol_value(sym(varint())));
    mrb_hash_set(M, h, mrb_symbol_value(sym(1)),
                 mrb_symbol_value(sym(varint())));
    const unsigned flags = *p++;
    if (flags & 1) {
      mrb_value v = value();
      mrb_hash_set(M, h, mrb_symbol_value(sym(2)), v);
      mrb_gc_arena_restore(M, ai);
    }
    if (flags & 2) {
      mrb_value v = value();
      mrb_hash_set(M, h, mrb_symbol_value(sym(3)), v);
      mrb_gc_arena_restore(M, ai);
    }
    if (flags & 4) {
      const unsigned n = varint();
      for (unsigned i = 0; i < n; ++i) {
        const mrb_sym key = sym(varint());
        mrb_value v = value();
        mrb_hash_set(M, h, mrb_symbol_value(key), v);
        mrb_gc_arena_restore(M, ai);
      }
    }
    return h;
  }
};

inline mrb_value Reader::value() {
  LCF_SCHEMA_GC(M);
  const unsigned char tag = *p++;
  switch (tag) {
    case 0:
      return mrb_nil_value();
    case 1:
      return mrb_true_value();
    case 2:
      return mrb_false_value();
    case 3: {
      // 64 bits: the zigzag of -2**31 is 2**32 - 1, and z + 1 wraps in an
      // unsigned.
      const unsigned long long z = varint();
      return mrb_int_value(M, (z & 1) ? -static_cast<mrb_int>((z + 1) >> 1)
                                      : static_cast<mrb_int>(z >> 1));
    }
    case 4: {
      double d;
      memcpy(&d, p, sizeof d);
      p += sizeof d;
      return mrb_float_value(M, d);
    }
    case 5:
      return mrb_symbol_value(sym(varint()));
    case 6: {
      size_t len;
      const char* s = str(varint(), &len);
      return mrb_str_new(M, s, len);
    }
    case 7: {
      const unsigned n = varint();
      mrb_value a = mrb_ary_new_capa(M, n);
      const int ai = mrb_gc_arena_save(M);
      for (unsigned i = 0; i < n; ++i) {
        mrb_ary_push(M, a, value());
        mrb_gc_arena_restore(M, ai);
      }
      return a;
    }
    case 8: {
      const unsigned n = varint();
      mrb_value h = mrb_hash_new_capa(M, n);
      const int ai = mrb_gc_arena_save(M);
      for (unsigned i = 0; i < n; ++i) {
        mrb_value k = value();
        mrb_value v = value();
        mrb_hash_set(M, h, k, v);
        mrb_gc_arena_restore(M, ai);
      }
      return h;
    }
    case 9:
      return mrb_const_get(M, mrb_obj_value(schema), sym(varint()));
    case 11:
      return field();
    default: {  // 12: Integer keys
      const unsigned n = varint();
      mrb_value h = mrb_hash_new_capa(M, n);
      const int ai = mrb_gc_arena_save(M);
      for (unsigned i = 0; i < n; ++i) {
        mrb_value k = mrb_int_value(M, varint());
        mrb_value v = value();
        mrb_hash_set(M, h, k, v);
        mrb_gc_arena_restore(M, ai);
      }
      return h;
    }
  }
}

// Table number `i` as a new Hash; raises IndexError for a number the build does
// not have.
inline mrb_value table(mrb_state* M, mrb_int i) {
  if (i < 0 || static_cast<unsigned>(i) >= lcf_schema_count) {
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(IndexError)),
               "no schema table %i", i);
  }
  RClass* lcf = mrb_module_get(M, "LCF");
  Reader r{M, mrb_module_get_under(M, lcf, "Schema"),
           lcf_schema_data + lcf_schema_off[i]};
  return r.value();
}

}  // namespace lcf_schema
