#include <mruby.h>
#include "cp932_lookup.hxx"

#include <optional>
#include <string>

#include <uni_algo/conv.h>

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
// (ADR 0111, 0217). A two-byte code is emitted big-endian, the order
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

}  // namespace

extern "C" void mrb_mruby_lcf_gem_init(mrb_state* M) {
  RClass* mod = mrb_define_module(M, "LCF");
  mrb_define_module_function(M, mod, "cp932_to_utf8", cp932_to_utf8,
                             MRB_ARGS_REQ(1));
  mrb_define_module_function(M, mod, "utf8_to_cp932", utf8_to_cp932,
                             MRB_ARGS_REQ(1));
}

extern "C" void mrb_mruby_lcf_gem_final(mrb_state* M) {}
