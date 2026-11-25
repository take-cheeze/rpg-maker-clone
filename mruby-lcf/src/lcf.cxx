#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include "cp932_lookup.hxx"

#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <string>

#include <uni_algo/conv.h>

#ifdef LCF_ROM_SCHEMA
#include "schema_rom.hxx"
#endif
#ifdef LCF_SCHEMA_TABLES
#include "schema_tables.hxx"
#endif

namespace {

mrb_value cp932_to_utf8(mrb_state* M, mrb_value self) {
  const uint8_t* p;
  mrb_int l;
  mrb_get_args(M, "s", &p, &l);

  std::u32string str;
  for (const uint8_t* i = p; i < p + l; ++i) {
    const uint8_t b[2] = {i[0],
                          static_cast<uint8_t>((p + l - i) >= 2 ? i[1] : 0x00)};
    std::optional<uint16_t> u = cp932_decode(b[0] << 8 | b[1]);
    if (u) {
      str.push_back(*u);
      i += 1;
      continue;
    }
    // ASCII characters
    if (b[0] < 0x80) {
      str.push_back(b[0]);
      continue;
    }
    u = cp932_decode(b[0]);
    if (u) {
      str.push_back(*u);
      continue;
    }
    // Unmappable byte: the best-fit table (used here in reverse as a decoder)
    // does not cover every valid CP932 code, and the input may contain
    // truncated multi-byte sequences or invalid bytes. Emit U+FFFD instead of
    // aborting the whole process. When the byte is a double-byte lead byte and
    // a trailing byte follows, consume both so the stream stays in sync.
    str.push_back(0xFFFD);
    const bool is_dbcs_lead =
        (b[0] >= 0x81 and b[0] <= 0x9F) or (b[0] >= 0xE0 and b[0] <= 0xFC);
    if (is_dbcs_lead and (p + l - i) >= 2)
      i += 1;
  }
  std::string ret = una::utf32to8(str);

  return mrb_str_new(M, ret.data(), ret.size());
}

// Inverse of cp932_to_utf8. The tables live in flash, never on the heap
// A two-byte code is emitted big-endian, the order
// cp932_to_utf8 reads it in.
mrb_value utf8_to_cp932(mrb_state* M, mrb_value self) {
  const uint8_t* p;
  mrb_int l;
  mrb_get_args(M, "s", &p, &l);

  const std::u32string str =
      una::utf8to32u(std::string(reinterpret_cast<const char*>(p), l));

  std::string ret;
  for (const char32_t c : str) {
    // ASCII passes through as a single raw byte, mirroring the decoder's
    // ASCII shortcut, which takes priority over any table entry.
    if (c < 0x80) {
      ret.push_back(static_cast<char>(c));
      continue;
    }
    const std::optional<uint16_t> b =
        c <= 0xffff ? cp932_encode(static_cast<uint16_t>(c)) : std::nullopt;
    if (!b) {
      // Unmappable code point: emit '?' rather than corrupting the byte
      // stream, matching cp932_to_utf8's best-effort handling on read.
      ret.push_back('?');
      continue;
    }
    if (*b > 0xff) {
      ret.push_back(static_cast<char>((*b >> 8) & 0xff));
      ret.push_back(static_cast<char>(*b & 0xff));
    } else {
      ret.push_back(static_cast<char>(*b & 0xff));
    }
  }

  return mrb_str_new(M, ret.data(), ret.size());
}

// INT32_CODEC: the LCF integer codecs work on the low 32 bits in uint32_t, so
// no intermediate leaves 32 bits and a 32-bit mrb_int build needs no bignum.
// Every result is an int32_t, which mrb_int holds on every target.
mrb_value int32_value(mrb_state* M, uint32_t v) {
  return mrb_int_value(M, static_cast<int32_t>(v));
}

[[noreturn]] void truncated_ber(mrb_state* M) {
  mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(RuntimeError)),
            "truncated BER integer");
}

// LCF.ber_value(d): the BER integer at the start of the String d, its low 32
// bits read as signed (RPG_RT writes -1 as 8f ff ff ff 7f).
mrb_value ber_value(mrb_state* M, mrb_value) {
  const uint8_t* p;
  mrb_int l;
  mrb_get_args(M, "s", &p, &l);
  uint32_t ret = 0;
  for (mrb_int i = 0;; ++i) {
    if (i >= l)
      truncated_ber(M);
    ret = (ret << 7) | (p[i] & 0x7f);
    if ((p[i] & 0x80) == 0)
      break;
  }
  return int32_value(M, ret);
}

// LCF.ber_shift(ret, b): read_ber's step from its fifth byte on, where the
// accumulated value no longer fits 31 bits; ret is the step's own result.
mrb_value ber_shift(mrb_state* M, mrb_value) {
  mrb_int ret, b;
  mrb_get_args(M, "ii", &ret, &b);
  return int32_value(
      M, (static_cast<uint32_t>(ret) << 7) | (static_cast<uint32_t>(b) & 0x7f));
}

// LCF.append_ber(out, n): appends n's low 32 bits to out as BER, shortest
// form (RPG_RT's own), and returns out.
mrb_value append_ber(mrb_state* M, mrb_value) {
  mrb_value out;
  mrb_int n;
  mrb_get_args(M, "Si", &out, &n);
  const uint32_t v = static_cast<uint32_t>(n);
  char buf[5];
  int len = 1;
  while (len < 5 && (v >> (7 * len)) != 0)
    ++len;
  for (int i = 0; i < len; ++i) {
    const uint32_t group = (v >> (7 * (len - 1 - i))) & 0x7f;
    buf[i] = static_cast<char>(i + 1 < len ? group | 0x80 : group);
  }
  mrb_str_cat(M, out, buf, len);
  return out;
}

// LCF.unpack_int32(d): the little-endian signed 32-bit integers of d; a
// trailing partial group is ignored.
mrb_value unpack_int32(mrb_state* M, mrb_value) {
  const uint8_t* p;
  mrb_int l;
  mrb_get_args(M, "s", &p, &l);
  const mrb_int n = l / 4;
  mrb_value out = mrb_ary_new_capa(M, n);
  for (mrb_int i = 0; i < n; ++i) {
    const int ai = mrb_gc_arena_save(M);
    const uint8_t* b = p + i * 4;
    const uint32_t v =
        b[0] | (b[1] << 8) | (b[2] << 16) | (static_cast<uint32_t>(b[3]) << 24);
    mrb_ary_push(M, out, int32_value(M, v));
    mrb_gc_arena_restore(M, ai);
  }
  return out;
}

// LCF.pack_int32(a): the inverse of unpack_int32, each value's low 32 bits.
mrb_value pack_int32(mrb_state* M, mrb_value) {
  mrb_value a;
  mrb_get_args(M, "A", &a);
  const mrb_int n = RARRAY_LEN(a);
  mrb_value out = mrb_str_new_capa(M, n * 4);
  for (mrb_int i = 0; i < n; ++i) {
    const uint32_t v =
        static_cast<uint32_t>(mrb_as_int(M, mrb_ary_ref(M, a, i)));
    const char b[4] = {static_cast<char>(v & 0xff),
                       static_cast<char>((v >> 8) & 0xff),
                       static_cast<char>((v >> 16) & 0xff),
                       static_cast<char>((v >> 24) & 0xff)};
    mrb_str_cat(M, out, b, 4);
  }
  return out;
}

#ifndef MRB_NO_FLOAT
// DOUBLE_CODEC: the save timestamp's IEEE-754 double, little-endian, read
// through its bit pattern so no 64-bit Integer is built. NaN is tested on the
// bits, which stays right under -ffinite-math-only.
constexpr uint64_t kDoubleExp = 0x7ff0000000000000ull;
constexpr uint64_t kDoubleFrac = 0x000fffffffffffffull;

// LCF.unpack_double(d): nil for nil or fewer than 8 bytes, else the double
// (any NaN as the platform's quiet NaN).
mrb_value unpack_double(mrb_state* M, mrb_value) {
  const char* p;
  mrb_int l;
  mrb_get_args(M, "s!", &p, &l);
  if (p == nullptr || l < 8)
    return mrb_nil_value();
  uint64_t bits = 0;
  for (int i = 7; i >= 0; --i)
    bits = (bits << 8) | static_cast<uint8_t>(p[i]);
  if ((bits & kDoubleExp) == kDoubleExp && (bits & kDoubleFrac) != 0)
    return mrb_float_value(M, std::numeric_limits<double>::quiet_NaN());
  double v;
  std::memcpy(&v, &bits, sizeof v);
  return mrb_float_value(M, v);
}

// LCF.pack_double(v): the 8 bytes of v (an Integer is converted). Every NaN
// becomes 7ff8000000000000, both zeros and every subnormal +-0 (the sign
// kept for a subnormal), and an infinity raises FloatDomainError.
mrb_value pack_double(mrb_state* M, mrb_value) {
  mrb_float f;
  mrb_get_args(M, "f", &f);
  double v = f;
  uint64_t bits;
  std::memcpy(&bits, &v, sizeof bits);
  const uint64_t exp = bits & kDoubleExp;
  if (exp == kDoubleExp && (bits & kDoubleFrac) != 0) {
    bits = 0x7ff8000000000000ull;
  } else if (exp == kDoubleExp) {
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(FloatDomainError)),
              "Infinity");
  } else if (exp == 0) {
    bits &= (bits & kDoubleFrac) != 0 ? 0x8000000000000000ull : 0;
  }
  char b[8];
  for (int i = 0; i < 8; ++i)
    b[i] = static_cast<char>((bits >> (8 * i)) & 0xff);
  return mrb_str_new(M, b, 8);
}
#endif

#ifdef LCF_SCHEMA_TABLES
// LCF.schema_table(n): the n-th folded `elements:` table
// (mruby-lcf/gen_schema_tables.rb), as a new Hash.
mrb_value schema_table(mrb_state* M, mrb_value) {
  mrb_int i;
  mrb_get_args(M, "i", &i);
  return lcf_schema::table(M, i);
}
#endif

// LCF.rom_get(node, key) / LCF.rom_keys(node): Hash#[] / Hash#keys of a ROM
// schema node (src/schema_rom.hxx). Registered in every build, so the closed
// world names the same methods with ROM_SCHEMA on or off; a build without the
// tables has no node to read. The bodies return through a call so the native
// base RBS reads no return class off a branch (base_rbs_native.rb).
#ifdef LCF_ROM_SCHEMA
mrb_value rom_get_of(mrb_state* M, mrb_value h, mrb_value key) {
  return lcf_rom::get(M, h, key);
}
mrb_value rom_keys_of(mrb_state* M, mrb_value h) {
  return lcf_rom::keys(M, h);
}
#else
[[noreturn]] void no_rom_schema(mrb_state* M) {
  mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(NotImplementedError)),
            "this build has no ROM schema");
}
mrb_value rom_get_of(mrb_state* M, mrb_value, mrb_value) {
  no_rom_schema(M);
}
mrb_value rom_keys_of(mrb_state* M, mrb_value) {
  no_rom_schema(M);
}
#endif

mrb_value rom_get(mrb_state* M, mrb_value) {
  mrb_value h, key;
  mrb_get_args(M, "oo", &h, &key);
  return rom_get_of(M, h, key);
}

mrb_value rom_keys(mrb_state* M, mrb_value) {
  mrb_value h;
  mrb_get_args(M, "o", &h);
  return rom_keys_of(M, h);
}

}  // namespace

// OWNER_CALL_DIRECT rows (NATIVE_ROWS in tools/bc2cpp/owner_call_direct.rb):
// the body of a ROM entry under an exported name, for the generated code of
// another gem; scripts/bc2cpp-rpg/owner_call_direct_native_check.rb holds them
// to the entries.
#define OWNER_ROW(wrapper, body)                    \
  mrb_value wrapper(mrb_state* M, mrb_value self) { \
    return body(M, self);                           \
  }
OWNER_ROW(lcf_row_s_utf8_to_cp932, utf8_to_cp932)
OWNER_ROW(lcf_row_utf8_to_cp932, utf8_to_cp932)
#undef OWNER_ROW

extern "C" void mrb_mruby_lcf_gem_init(mrb_state* M) {
  RClass* mod = mrb_define_module(M, "LCF");
#define MRB_MT_CLASS LCF_singleton
  static const mrb_mt_entry mod_module_functions[] = {
      MRB_MT_ENTRY(cp932_to_utf8, MRB_SYM(cp932_to_utf8), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(utf8_to_cp932, MRB_SYM(utf8_to_cp932), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(rom_get, MRB_SYM(rom_get), MRB_ARGS_REQ(2))              //
      MRB_MT_ENTRY(rom_keys, MRB_SYM(rom_keys), MRB_ARGS_REQ(1))            //
#ifdef LCF_SCHEMA_TABLES
      MRB_MT_ENTRY(schema_table, MRB_SYM(schema_table), MRB_ARGS_REQ(1))  //
#endif
      MRB_MT_ENTRY(ber_value, MRB_SYM(ber_value), MRB_ARGS_REQ(1))        //
      MRB_MT_ENTRY(ber_shift, MRB_SYM(ber_shift), MRB_ARGS_REQ(2))        //
      MRB_MT_ENTRY(append_ber, MRB_SYM(append_ber), MRB_ARGS_REQ(2))      //
      MRB_MT_ENTRY(unpack_int32, MRB_SYM(unpack_int32), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(pack_int32, MRB_SYM(pack_int32), MRB_ARGS_REQ(1))      //
#ifndef MRB_NO_FLOAT
      MRB_MT_ENTRY(unpack_double, MRB_SYM(unpack_double), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(pack_double, MRB_SYM(pack_double), MRB_ARGS_REQ(1))      //
#endif
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(mod)),
                  mod_module_functions);
#define MRB_MT_CLASS LCF
  static const mrb_mt_entry mod_module_functions_private[] = {
      MRB_MT_ENTRY(cp932_to_utf8, MRB_SYM(cp932_to_utf8),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(utf8_to_cp932, MRB_SYM(utf8_to_cp932),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(rom_get, MRB_SYM(rom_get),
                   MRB_ARGS_REQ(2) | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(rom_keys, MRB_SYM(rom_keys),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
#ifdef LCF_SCHEMA_TABLES
      MRB_MT_ENTRY(schema_table, MRB_SYM(schema_table),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
#endif
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mod, mod_module_functions_private);
}

extern "C" void mrb_mruby_lcf_gem_final(mrb_state* M) {}
