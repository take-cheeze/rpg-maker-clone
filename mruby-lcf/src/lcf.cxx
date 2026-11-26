#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/data.h>
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

mrb_value cp932_str_to_utf8(mrb_state* M, const uint8_t* p, mrb_int l) {
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

mrb_value cp932_to_utf8(mrb_state* M, mrb_value self) {
  const uint8_t* p;
  mrb_int l;
  mrb_get_args(M, "s", &p, &l);
  return cp932_str_to_utf8(M, p, l);
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

// CURSOR: a BER integer read at byte +pos+ of a String, so a record in memory
// is parsed through a position instead of a StringIO. +pos+ is left just past
// the integer; running off the end raises as read_ber does.
uint32_t ber_read(mrb_state* M, const uint8_t* p, mrb_int l, mrb_int& pos) {
  if (pos < 0)
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(ArgumentError)),
              "negative LCF position");
  uint32_t ret = 0;
  for (;;) {
    if (pos >= l)
      truncated_ber(M);
    const uint8_t b = p[pos++];
    ret = (ret << 7) | (b & 0x7f);
    if ((b & 0x80) == 0)
      return ret;
  }
}

// LCF.ber_at(s, pos): the BER integer at byte pos of s, as read_ber reads it.
mrb_value ber_at(mrb_state* M, mrb_value) {
  const uint8_t* p;
  mrb_int l, pos;
  mrb_get_args(M, "si", &p, &l, &pos);
  return int32_value(M, ber_read(M, p, l, pos));
}

// LCF.ber_next(s, pos): the position just past the BER integer at pos.
mrb_value ber_next(mrb_state* M, mrb_value) {
  const uint8_t* p;
  mrb_int l, pos;
  mrb_get_args(M, "si", &p, &l, &pos);
  ber_read(M, p, l, pos);
  return mrb_int_value(M, pos);
}

// LCF.row_end(s, pos): the end of the table row whose chunks start at pos,
// just past its id-0 terminator (or the end of s), checking every chunk's
// length as Array2D#read_row_slice does.
mrb_value row_end(mrb_state* M, mrb_value) {
  const uint8_t* p;
  mrb_int l, pos;
  mrb_get_args(M, "si", &p, &l, &pos);
  while (pos < l) {
    const mrb_int idx = static_cast<int32_t>(ber_read(M, p, l, pos));
    if (idx == 0)
      break;
    const mrb_int len = static_cast<int32_t>(ber_read(M, p, l, pos));
    if (len < 0 || len > l - pos)
      mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(RuntimeError)),
                 "truncated chunk %i: %i bytes declared", idx, len);
    pos += len;
  }
  return mrb_int_value(M, pos);
}

// EVENT_LIST: an :event_packed command list (LCF::EventList) is its LCF bytes
// plus an index String of each command's start offset, little-endian, 2 bytes
// an entry when every offset fits in 16 bits and 4 otherwise. A command is
// code, indent, string length + cp932 bytes, parameter count + parameters, each
// a BER integer, as LCF.parse_event_commands reads it.
mrb_int event_index_width(mrb_int bytes_len) {
  return bytes_len <= 0xffff ? 2 : 4;
}

// Moves pos past the command that starts there; a command cut short raises.
void event_skip(mrb_state* M, const uint8_t* p, mrb_int l, mrb_int& pos) {
  ber_read(M, p, l, pos);  // code
  ber_read(M, p, l, pos);  // indent
  const mrb_int slen = static_cast<int32_t>(ber_read(M, p, l, pos));
  if (slen > 0) {
    if (slen > l - pos)
      truncated_ber(M);
    pos += slen;
  }
  const mrb_int pcount = static_cast<int32_t>(ber_read(M, p, l, pos));
  for (mrb_int i = 0; i < pcount; ++i)
    ber_read(M, p, l, pos);
}

// LCF.event_index(bytes): the index of bytes, which is checked whole first (a
// command cut short raises, as parse_event_commands does), so the String is
// allocated at its exact size.
mrb_value event_index(mrb_state* M, mrb_value) {
  const uint8_t* p;
  mrb_int l;
  mrb_get_args(M, "s", &p, &l);
  mrb_int count = 0;
  for (mrb_int pos = 0; pos < l; ++count)
    event_skip(M, p, l, pos);
  const mrb_int width = event_index_width(l);
  mrb_value out = mrb_str_new_capa(M, count * width);
  for (mrb_int pos = 0; pos < l;) {
    char b[4];
    for (mrb_int i = 0; i < width; ++i)
      b[i] = static_cast<char>((static_cast<uint32_t>(pos) >> (8 * i)) & 0xff);
    mrb_str_cat(M, out, b, width);
    event_skip(M, p, l, pos);
  }
  return out;
}

mrb_int event_count_of(mrb_int bytes_len, mrb_value index) {
  return RSTRING_LEN(index) / event_index_width(bytes_len);
}

// The start offset of command i (IndexError outside the list).
mrb_int event_start(mrb_state* M,
                    mrb_int bytes_len,
                    mrb_value index,
                    mrb_int i) {
  const mrb_int width = event_index_width(bytes_len);
  if (i < 0 || i >= event_count_of(bytes_len, index))
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(IndexError)),
               "event command %i outside the list", i);
  const uint8_t* e =
      reinterpret_cast<const uint8_t*>(RSTRING_PTR(index)) + i * width;
  uint32_t at = 0;
  for (mrb_int k = width - 1; k >= 0; --k)
    at = (at << 8) | e[k];
  return static_cast<mrb_int>(at);
}

// LCF.event_count(bytes, index): the number of commands.
mrb_value event_count(mrb_state* M, mrb_value) {
  mrb_value bytes, index;
  mrb_get_args(M, "SS", &bytes, &index);
  return mrb_int_value(M, event_count_of(RSTRING_LEN(bytes), index));
}

// The position of field +field+ (0 code, 1 indent, 2 string length, 3
// parameter count) of command i.
mrb_int event_field(mrb_state* M,
                    mrb_value bytes,
                    mrb_value index,
                    mrb_int i,
                    int field) {
  const uint8_t* p = reinterpret_cast<const uint8_t*>(RSTRING_PTR(bytes));
  const mrb_int l = RSTRING_LEN(bytes);
  mrb_int pos = event_start(M, l, index, i);
  for (int f = 0; f < field; ++f) {
    const mrb_int v = static_cast<int32_t>(ber_read(M, p, l, pos));
    if (f == 2 && v > 0)
      pos += v;
  }
  return pos;
}

mrb_value event_ber_field(mrb_state* M, int field) {
  mrb_value bytes, index;
  mrb_int i;
  mrb_get_args(M, "SSi", &bytes, &index, &i);
  mrb_int pos = event_field(M, bytes, index, i, field);
  return int32_value(
      M, ber_read(M, reinterpret_cast<const uint8_t*>(RSTRING_PTR(bytes)),
                  RSTRING_LEN(bytes), pos));
}

// LCF.event_code(bytes, index, i) / LCF.event_indent(bytes, index, i).
mrb_value event_code(mrb_state* M, mrb_value) {
  return event_ber_field(M, 0);
}

mrb_value event_indent(mrb_state* M, mrb_value) {
  return event_ber_field(M, 1);
}

// LCF.event_string(bytes, index, i): command i's string as UTF-8, nil when it
// is empty (the caller hands out LCF.empty_str, as parse_event_commands does).
mrb_value event_string(mrb_state* M, mrb_value) {
  mrb_value bytes, index;
  mrb_int i;
  mrb_get_args(M, "SSi", &bytes, &index, &i);
  const uint8_t* p = reinterpret_cast<const uint8_t*>(RSTRING_PTR(bytes));
  const mrb_int l = RSTRING_LEN(bytes);
  mrb_int pos = event_field(M, bytes, index, i, 2);
  const mrb_int slen = static_cast<int32_t>(ber_read(M, p, l, pos));
  if (slen <= 0)
    return mrb_nil_value();
  if (slen > l - pos)
    truncated_ber(M);
  return cp932_str_to_utf8(M, p + pos, slen);
}

// LCF.event_params(bytes, index, i): command i's parameters, a new Array.
mrb_value event_params(mrb_state* M, mrb_value) {
  mrb_value bytes, index;
  mrb_int i;
  mrb_get_args(M, "SSi", &bytes, &index, &i);
  const uint8_t* p = reinterpret_cast<const uint8_t*>(RSTRING_PTR(bytes));
  const mrb_int l = RSTRING_LEN(bytes);
  mrb_int pos = event_field(M, bytes, index, i, 3);
  const mrb_int pcount = static_cast<int32_t>(ber_read(M, p, l, pos));
  mrb_value out = mrb_ary_new_capa(M, pcount > 0 ? pcount : 0);
  for (mrb_int k = 0; k < pcount; ++k) {
    const int ai = mrb_gc_arena_save(M);
    mrb_ary_push(M, out, int32_value(M, ber_read(M, p, l, pos)));
    mrb_gc_arena_restore(M, ai);
  }
  return out;
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
  mrb_value d;
  mrb_get_args(M, "o", &d);
  if (mrb_nil_p(d))
    return mrb_nil_value();
  d = mrb_ensure_string_type(M, d);
  const char* p = RSTRING_PTR(d);
  if (RSTRING_LEN(d) < 8)
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

// LCF::ShortArray: a fixed-size table of signed 16-bit integers, two bytes an
// element where an Array of Integers takes a word (the map layers, schema
// type :int16_packed). One allocation of exactly its size; a write outside
// the table or the int16 range raises instead of growing or truncating.
struct ShortArray {
  mrb_int len;
  int16_t* elems() { return reinterpret_cast<int16_t*>(this + 1); }
};

void short_array_free(mrb_state* M, void* p) {
  mrb_free(M, p);
}

const mrb_data_type short_array_type = {"LCF::ShortArray", short_array_free};

ShortArray* short_array_new(mrb_state* M, mrb_int len) {
  if (len < 0 ||
      len > (MRB_INT_MAX - static_cast<mrb_int>(sizeof(ShortArray))) / 2)
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(ArgumentError)),
              "invalid LCF::ShortArray size");
  auto* a = static_cast<ShortArray*>(
      mrb_malloc(M, sizeof(ShortArray) + sizeof(int16_t) * len));
  a->len = len;
  std::memset(a->elems(), 0, sizeof(int16_t) * len);
  return a;
}

ShortArray* short_array_get(mrb_state* M, mrb_value self) {
  auto* a =
      static_cast<ShortArray*>(mrb_data_get_ptr(M, self, &short_array_type));
  if (!a)
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(TypeError)),
              "uninitialized LCF::ShortArray");
  return a;
}

// ShortArray.new(n): n zeros.
mrb_value short_array_init(mrb_state* M, mrb_value self) {
  mrb_int len;
  mrb_get_args(M, "i", &len);
  ShortArray* a = short_array_new(M, len);
  if (DATA_PTR(self))
    mrb_free(M, DATA_PTR(self));
  mrb_data_init(self, a, &short_array_type);
  return self;
}

mrb_value short_array_init_copy(mrb_state* M, mrb_value self) {
  mrb_value src;
  mrb_get_args(M, "o", &src);
  ShortArray* from = short_array_get(M, src);
  ShortArray* a = short_array_new(M, from->len);
  std::memcpy(a->elems(), from->elems(), sizeof(int16_t) * from->len);
  if (DATA_PTR(self))
    mrb_free(M, DATA_PTR(self));
  mrb_data_init(self, a, &short_array_type);
  return self;
}

// ShortArray.unpack(d): the little-endian signed 16-bit integers of d, as
// d.unpack('s<*') reads them (a trailing odd byte is ignored).
mrb_value short_array_s_unpack(mrb_state* M, mrb_value self) {
  const uint8_t* p;
  mrb_int l;
  mrb_get_args(M, "s", &p, &l);
  // The object first, so a failed table allocation leaks nothing.
  RData* d =
      mrb_data_object_alloc(M, mrb_class_ptr(self), nullptr, &short_array_type);
  ShortArray* a = short_array_new(M, l / 2);
  int16_t* e = a->elems();
  for (mrb_int i = 0; i < a->len; ++i)
    e[i] = static_cast<int16_t>(p[2 * i] | (p[2 * i + 1] << 8));
  d->data = a;
  return mrb_obj_value(d);
}

// get(i), self[i] (lcf.rb): the element, nil outside the table; a negative i
// counts from the end, as Array#[] does.
mrb_value short_array_aref(mrb_state* M, mrb_value self) {
  mrb_int i;
  mrb_get_args(M, "i", &i);
  ShortArray* a = short_array_get(M, self);
  if (i < 0)
    i += a->len;
  if (i < 0 || i >= a->len)
    return mrb_nil_value();
  return mrb_fixnum_value(a->elems()[i]);
}

// set(i, v), self[i] = v (lcf.rb): IndexError outside the table, RangeError
// outside int16.
mrb_value short_array_aset(mrb_state* M, mrb_value self) {
  mrb_int i;
  mrb_value v;
  mrb_get_args(M, "io", &i, &v);
  ShortArray* a = short_array_get(M, self);
  const mrb_int at = i < 0 ? i + a->len : i;
  if (at < 0 || at >= a->len)
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(IndexError)),
               "index %i outside LCF::ShortArray of size %i", i, a->len);
  if (!mrb_integer_p(v)) {
    if (mrb_obj_is_kind_of(M, v, M->integer_class))
      mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(RangeError)),
                 "%v is outside int16 (-32768..32767)", v);
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(TypeError)),
               "%T is not an Integer", v);
  }
  const mrb_int n = mrb_integer(v);
  if (n < -32768 || n > 32767)
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(RangeError)),
               "%i is outside int16 (-32768..32767)", n);
  a->elems()[at] = static_cast<int16_t>(n);
  return v;
}

mrb_value short_array_size(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(short_array_get(M, self)->len);
}

// each { |v| }: the table is fixed-size, but the block may write to it, so
// every element is read when it is yielded.
mrb_value short_array_each(mrb_state* M, mrb_value self) {
  mrb_value blk;
  mrb_get_args(M, "&", &blk);
  if (mrb_nil_p(blk))
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(ArgumentError)),
              "no block given");
  for (mrb_int i = 0; i < short_array_get(M, self)->len; ++i)
    mrb_yield(M, blk, mrb_fixnum_value(short_array_get(M, self)->elems()[i]));
  return self;
}

mrb_value short_array_to_a(mrb_state* M, mrb_value self) {
  ShortArray* a = short_array_get(M, self);
  mrb_value out = mrb_ary_new_capa(M, a->len);
  for (mrb_int i = 0; i < a->len; ++i)
    mrb_ary_push(M, out, mrb_fixnum_value(a->elems()[i]));
  return out;
}

// to_lcf: the chunk bytes, little-endian, the inverse of .unpack.
mrb_value short_array_to_lcf(mrb_state* M, mrb_value self) {
  ShortArray* a = short_array_get(M, self);
  mrb_value out = mrb_str_new_capa(M, a->len * 2);
  for (mrb_int i = 0; i < a->len; ++i) {
    const uint16_t v = static_cast<uint16_t>(a->elems()[i]);
    const char b[2] = {static_cast<char>(v & 0xff), static_cast<char>(v >> 8)};
    mrb_str_cat(M, out, b, 2);
  }
  return out;
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
      MRB_MT_ENTRY(ber_at, MRB_SYM(ber_at), MRB_ARGS_REQ(2))              //
      MRB_MT_ENTRY(ber_next, MRB_SYM(ber_next), MRB_ARGS_REQ(2))          //
      MRB_MT_ENTRY(row_end, MRB_SYM(row_end), MRB_ARGS_REQ(2))            //
      MRB_MT_ENTRY(event_index, MRB_SYM(event_index), MRB_ARGS_REQ(1))    //
      MRB_MT_ENTRY(event_count, MRB_SYM(event_count), MRB_ARGS_REQ(2))    //
      MRB_MT_ENTRY(event_code, MRB_SYM(event_code), MRB_ARGS_REQ(3))      //
      MRB_MT_ENTRY(event_indent, MRB_SYM(event_indent), MRB_ARGS_REQ(3))  //
      MRB_MT_ENTRY(event_string, MRB_SYM(event_string), MRB_ARGS_REQ(3))  //
      MRB_MT_ENTRY(event_params, MRB_SYM(event_params), MRB_ARGS_REQ(3))  //
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
  // Registered here, where `mod` names LCF for the native base RBS scan.
  RClass* short_array =
      mrb_define_class_under(M, mod, "ShortArray", M->object_class);
  MRB_SET_INSTANCE_TT(short_array, MRB_TT_DATA);
#define MRB_MT_CLASS LCF__ShortArray
  static const mrb_mt_entry short_array_methods[] = {
      MRB_MT_ENTRY(short_array_init, MRB_SYM(initialize),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(short_array_init_copy, MRB_SYM(initialize_copy),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)                      //
      MRB_MT_ENTRY(short_array_aref, MRB_SYM(get), MRB_ARGS_REQ(1))       //
      MRB_MT_ENTRY(short_array_aset, MRB_SYM(set), MRB_ARGS_REQ(2))       //
      MRB_MT_ENTRY(short_array_size, MRB_SYM(size), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(short_array_each, MRB_SYM(each), MRB_ARGS_BLOCK())     //
      MRB_MT_ENTRY(short_array_to_a, MRB_SYM(to_a), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(short_array_to_lcf, MRB_SYM(to_lcf), MRB_ARGS_NONE())  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, short_array, short_array_methods);
#define MRB_MT_CLASS LCF__ShortArray_singleton
  static const mrb_mt_entry short_array_class_methods[] = {
      MRB_MT_ENTRY(short_array_s_unpack, MRB_SYM(unpack), MRB_ARGS_REQ(1))  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(short_array)),
                  short_array_class_methods);
}

extern "C" void mrb_mruby_lcf_gem_final(mrb_state* M) {}
